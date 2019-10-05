//
// Copyright 2019 The ANGLE Project Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//

#include "libANGLE/renderer/metal/UtilsMtl.h"

#include <utility>

#include "common/debug.h"
#include "libANGLE/renderer/metal/ContextMtl.h"
#include "libANGLE/renderer/metal/RendererMtl.h"
#include "libANGLE/renderer/metal/mtl_common.h"
#include "libANGLE/renderer/metal/mtl_utils.h"
#include "libANGLE/renderer/metal/shaders/compiled/mtl_default_shaders.inc"

namespace rx
{
namespace
{

struct ClearParamsUniform
{
    float clearColor[4];
    float clearDepth;
    float padding[3];
};

struct BlitParamsUniform
{
    // 0: lower left, 1: lower right, 2: upper left, 3: upper right
    float srcTexCoords[4][2];
    int srcLevel         = 0;
    uint8_t srcLuminance = 0;  // source texture is luminance texture
    uint8_t dstFlipY     = 0;
    uint8_t dstLuminance = 0;  // dest texture is luminace
    uint8_t padding1;
    float padding2[2];
};

}  // namespace

UtilsMtl::UtilsMtl(RendererMtl *renderer) : mtl::Context(renderer) {}

UtilsMtl::~UtilsMtl() {}

angle::Result UtilsMtl::initialize()
{
    auto re = initShaderLibrary();
    if (re != angle::Result::Continue)
    {
        return re;
    }

    initClearResources();
    initBlitResources();

    return angle::Result::Continue;
}

void UtilsMtl::onDestroy()
{
    mDefaultShaders = nil;

    mClearRenderPipelineCache.clear();
    mBlitRenderPipelineCache.clear();
    mBlitPremultiplyAlphaRenderPipelineCache.clear();
    mBlitUnmultiplyAlphaRenderPipelineCache.clear();
}

// override mtl::ErrorHandler
void UtilsMtl::handleError(GLenum glErrorCode,
                           const char *file,
                           const char *function,
                           unsigned int line)
{
    ERR() << "Metal backend encountered an internal error. Code=" << glErrorCode << ".";
}

void UtilsMtl::handleError(NSError *nserror,
                           const char *file,
                           const char *function,
                           unsigned int line)
{
    if (!nserror)
    {
        return;
    }

    std::stringstream errorStream;
    ERR() << "Metal backend encountered an internal error: \n"
          << nserror.localizedDescription.UTF8String;
}

angle::Result UtilsMtl::initShaderLibrary()
{
    NSError *err    = nil;
    mDefaultShaders = mtl::CreateShaderLibraryFromBinary(getRenderer()->getMetalDevice(),
                                                         compiled_default_metallib,
                                                         compiled_default_metallib_len, &err);

    if (err && !mDefaultShaders)
    {
        ANGLE_MTL_CHECK_WITH_ERR(this, false, err);
        return angle::Result::Stop;
    }

    return angle::Result::Continue;
}

void UtilsMtl::initClearResources()
{
    ANGLE_MTL_OBJC_SCOPE
    {
        // Shader pipeline
        mClearRenderPipelineCache.setVertexShader(
            this, [mDefaultShaders.get() newFunctionWithName:@"clearVS"]);
        mClearRenderPipelineCache.setFragmentShader(
            this, [mDefaultShaders.get() newFunctionWithName:@"clearFS"]);
    }
}

void UtilsMtl::initBlitResources()
{
    ANGLE_MTL_OBJC_SCOPE
    {
        auto shaderLib    = mDefaultShaders.get();
        auto vertexShader = [shaderLib newFunctionWithName:@"blitVS"];

        mBlitRenderPipelineCache.setVertexShader(this, vertexShader);
        mBlitRenderPipelineCache.setFragmentShader(this, [shaderLib newFunctionWithName:@"blitFS"]);

        mBlitPremultiplyAlphaRenderPipelineCache.setVertexShader(this, vertexShader);
        mBlitPremultiplyAlphaRenderPipelineCache.setFragmentShader(
            this, [shaderLib newFunctionWithName:@"blitPremultiplyAlphaFS"]);

        mBlitUnmultiplyAlphaRenderPipelineCache.setVertexShader(this, vertexShader);
        mBlitUnmultiplyAlphaRenderPipelineCache.setFragmentShader(
            this, [shaderLib newFunctionWithName:@"blitUnmultiplyAlphaFS"]);
    }
}

void UtilsMtl::clearWithDraw(const gl::Context *context,
                             mtl::RenderCommandEncoder *cmdEncoder,
                             const ClearParams &params)
{
    if (!params.clearColor.valid() && !params.clearDepth.valid() && !params.clearStencil.valid())
    {
        return;
    }

    setupClearWithDraw(context, cmdEncoder, params);

    // Draw the screen aligned quad
    cmdEncoder->draw(MTLPrimitiveTypeTriangle, 0, 6);

    // Invalidate current context's state
    auto contextMtl = mtl::GetImpl(context);
    contextMtl->invalidateState(context);
}

void UtilsMtl::blitWithDraw(const gl::Context *context,
                            mtl::RenderCommandEncoder *cmdEncoder,
                            const BlitParams &params)
{
    if (!params.src)
    {
        return;
    }
    setupBlitWithDraw(context, cmdEncoder, params);

    // Draw the screen aligned quad
    cmdEncoder->draw(MTLPrimitiveTypeTriangle, 0, 6);

    // Invalidate current context's state
    ContextMtl *contextMtl = mtl::GetImpl(context);
    contextMtl->invalidateState(context);
}

void UtilsMtl::setupClearWithDraw(const gl::Context *context,
                                  mtl::RenderCommandEncoder *cmdEncoder,
                                  const ClearParams &params)
{
    // Generate render pipeline state
    auto renderPipelineState = getClearRenderPipelineState(context, cmdEncoder, params);
    ASSERT(renderPipelineState);
    // Setup states
    setupDrawScreenQuadCommonStates(cmdEncoder);
    cmdEncoder->setRenderPipelineState(renderPipelineState);

    id<MTLDepthStencilState> dsState = getClearDepthStencilState(context, params);
    cmdEncoder->setDepthStencilState(dsState).setStencilRefVal(params.clearStencil.value());

    // Viewports
    const mtl::RenderPassDesc &renderPassDesc = cmdEncoder->renderPassDesc();

    ASSERT(renderPassDesc.numColorAttachments == 1);

    MTLViewport viewport;
    MTLScissorRect scissorRect;
    const mtl::RenderPassColorAttachmentDesc &renderPassColorAttachment =
        renderPassDesc.colorAttachments[0];
    auto texture = renderPassColorAttachment.texture.lock();

    viewport = mtl::GetViewport(params.clearArea, texture->height(renderPassColorAttachment.level),
                                params.flipY);

    scissorRect = mtl::GetScissorRect(
        params.clearArea, texture->height(renderPassColorAttachment.level), params.flipY);

    cmdEncoder->setViewport(viewport);
    cmdEncoder->setScissorRect(scissorRect);

    // uniform
    ClearParamsUniform uniformParams;
    uniformParams.clearColor[0] = static_cast<float>(params.clearColor.value().red);
    uniformParams.clearColor[1] = static_cast<float>(params.clearColor.value().green);
    uniformParams.clearColor[2] = static_cast<float>(params.clearColor.value().blue);
    uniformParams.clearColor[3] = static_cast<float>(params.clearColor.value().alpha);
    uniformParams.clearDepth    = params.clearDepth.value();

    cmdEncoder->setVertexData(uniformParams, 0);
    cmdEncoder->setFragmentData(uniformParams, 0);
}

void UtilsMtl::setupBlitWithDraw(const gl::Context *context,
                                 mtl::RenderCommandEncoder *cmdEncoder,
                                 const BlitParams &params)
{
    ASSERT(cmdEncoder->renderPassDesc().numColorAttachments == 1 && params.src);

    // Generate render pipeline state
    auto renderPipelineState = getBlitRenderPipelineState(context, cmdEncoder, params);
    ASSERT(renderPipelineState);
    // Setup states
    setupDrawScreenQuadCommonStates(cmdEncoder);
    cmdEncoder->setRenderPipelineState(renderPipelineState);
    cmdEncoder->setDepthStencilState(getRenderer()->getStateCache().getNullDepthStencilState(this));

    // Viewport
    const mtl::RenderPassDesc &renderPassDesc = cmdEncoder->renderPassDesc();
    const mtl::RenderPassColorAttachmentDesc &renderPassColorAttachment =
        renderPassDesc.colorAttachments[0];
    auto texture = renderPassColorAttachment.texture.lock();

    gl::Rectangle dstRect(params.dstOffset.x, params.dstOffset.y, params.srcRect.width,
                          params.srcRect.height);
    MTLViewport viewportMtl = mtl::GetViewport(
        dstRect, texture->height(renderPassColorAttachment.level), params.dstFlipY);
    MTLScissorRect scissorRectMtl = mtl::GetScissorRect(
        dstRect, texture->height(renderPassColorAttachment.level), params.dstFlipY);
    cmdEncoder->setViewport(viewportMtl);
    cmdEncoder->setScissorRect(scissorRectMtl);

    // Uniform
    setupBlitWithDrawUniformData(cmdEncoder, params);
}

void UtilsMtl::setupDrawScreenQuadCommonStates(mtl::RenderCommandEncoder *cmdEncoder)
{
    cmdEncoder->setCullMode(MTLCullModeNone);
    cmdEncoder->setTriangleFillMode(MTLTriangleFillModeFill);
    cmdEncoder->setDepthBias(0, 0, 0);
}

id<MTLDepthStencilState> UtilsMtl::getClearDepthStencilState(const gl::Context *context,
                                                             const ClearParams &params)
{
    if (!params.clearDepth.valid() && !params.clearStencil.valid())
    {
        // Doesn't clear depth nor stencil
        return getRenderer()->getStateCache().getNullDepthStencilState(this);
    }

    ContextMtl *contextMtl = mtl::GetImpl(context);

    mtl::DepthStencilDesc desc;
    desc.set();

    if (params.clearDepth.valid())
    {
        // Clear depth state
        desc.depthWriteEnabled = true;
    }
    else
    {
        desc.depthWriteEnabled = false;
    }

    if (params.clearStencil.valid())
    {
        // Clear stencil state
        desc.frontFaceStencil.depthStencilPassOperation = MTLStencilOperationReplace;
        desc.frontFaceStencil.writeMask                 = contextMtl->getStencilMask();
        desc.backFaceStencil.depthStencilPassOperation  = MTLStencilOperationReplace;
        desc.backFaceStencil.writeMask                  = contextMtl->getStencilMask();
    }

    return getRenderer()->getStateCache().getDepthStencilState(getRenderer()->getMetalDevice(),
                                                               desc);
}

id<MTLRenderPipelineState> UtilsMtl::getClearRenderPipelineState(
    const gl::Context *context,
    mtl::RenderCommandEncoder *cmdEncoder,
    const ClearParams &params)
{
    ContextMtl *contextMtl      = mtl::GetImpl(context);
    MTLColorWriteMask colorMask = contextMtl->getColorMask();

    mtl::RenderPipelineDesc pipelineDesc;
    const mtl::RenderPassDesc &renderPassDesc = cmdEncoder->renderPassDesc();

    renderPassDesc.populateRenderPipelineOutputDesc(colorMask, &pipelineDesc.outputDescriptor);

    pipelineDesc.inputPrimitiveTopology = mtl::kPrimitiveTopologyClassTriangle;

    return mClearRenderPipelineCache.getRenderPipelineState(contextMtl, pipelineDesc);
}

id<MTLRenderPipelineState> UtilsMtl::getBlitRenderPipelineState(
    const gl::Context *context,
    mtl::RenderCommandEncoder *cmdEncoder,
    const BlitParams &params)
{
    ContextMtl *contextMtl = mtl::GetImpl(context);
    mtl::RenderPipelineDesc pipelineDesc;
    const mtl::RenderPassDesc &renderPassDesc = cmdEncoder->renderPassDesc();

    renderPassDesc.populateRenderPipelineOutputDesc(params.dstColorMask,
                                                    &pipelineDesc.outputDescriptor);

    pipelineDesc.inputPrimitiveTopology = mtl::kPrimitiveTopologyClassTriangle;

    RenderPipelineCacheMtl *pipelineCache;
    if (params.unpackPremultiplyAlpha == params.unpackUnmultiplyAlpha)
    {
        pipelineCache = &mBlitRenderPipelineCache;
    }
    else if (params.unpackPremultiplyAlpha)
    {
        pipelineCache = &mBlitPremultiplyAlphaRenderPipelineCache;
    }
    else
    {
        pipelineCache = &mBlitUnmultiplyAlphaRenderPipelineCache;
    }

    return pipelineCache->getRenderPipelineState(contextMtl, pipelineDesc);
}

void UtilsMtl::setupBlitWithDrawUniformData(mtl::RenderCommandEncoder *cmdEncoder,
                                            const BlitParams &params)
{
    BlitParamsUniform uniformParams;
    uniformParams.dstFlipY     = params.dstFlipY ? 1 : 0;
    uniformParams.srcLevel     = params.srcLevel;
    uniformParams.dstLuminance = params.dstLuminance ? 1 : 0;

    // Compute source texCoords
    auto srcWidth  = params.src->width(params.srcLevel);
    auto srcHeight = params.src->height(params.srcLevel);

    int x0 = params.srcRect.x0();
    int x1 = params.srcRect.x1();
    int y0 = params.srcRect.y0();
    int y1 = params.srcRect.y1();
    if (params.srcYFlipped)
    {
        y0 = srcHeight - y1;
        y1 = y0 + params.srcRect.height;

        std::swap(y0, y1);
    }

    if (params.unpackFlipY)
    {
        std::swap(y0, y1);
    }

    float u0 = (float)x0 / srcWidth;
    float u1 = (float)x1 / srcWidth;
    float v0 = (float)y0 / srcHeight;
    float v1 = (float)y1 / srcHeight;

    // lower left
    uniformParams.srcTexCoords[0][0] = u0;
    uniformParams.srcTexCoords[0][1] = v0;

    // lower right
    uniformParams.srcTexCoords[1][0] = u1;
    uniformParams.srcTexCoords[1][1] = v0;

    // upper left
    uniformParams.srcTexCoords[2][0] = u0;
    uniformParams.srcTexCoords[2][1] = v1;

    // upper right
    uniformParams.srcTexCoords[3][0] = u1;
    uniformParams.srcTexCoords[3][1] = v1;

    cmdEncoder->setVertexData(uniformParams, 0);
    cmdEncoder->setFragmentData(uniformParams, 0);
}

}  // namespace rx