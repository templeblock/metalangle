//
// Copyright 2019 The ANGLE Project Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//

#include "libANGLE/renderer/metal/ProgramMtl.h"

#include <TargetConditionals.h>

#include <sstream>

#include <spirv_msl.hpp>

#include "common/debug.h"
#include "libANGLE/Context.h"
#include "libANGLE/ProgramLinkedResources.h"
#include "libANGLE/renderer/metal/ContextMtl.h"
#include "libANGLE/renderer/metal/GlslangWrapper.h"
#include "libANGLE/renderer/metal/RendererMtl.h"
#include "libANGLE/renderer/metal/TextureMtl.h"
#include "libANGLE/renderer/metal/mtl_utils.h"
#include "libANGLE/renderer/renderer_utils.h"

namespace rx
{

namespace
{

#define SHADER_ENTRY_NAME @"main0"

spv::ExecutionModel ShaderTypeToSpvExecutionModel(gl::ShaderType shaderType)
{
    switch (shaderType)
    {
        case gl::ShaderType::Vertex:
            return spv::ExecutionModelVertex;
        case gl::ShaderType::Fragment:
            return spv::ExecutionModelFragment;
        default:
            UNREACHABLE();
            return spv::ExecutionModelMax;
    }
}

typedef uint32_t(spirv_cross::MSLResourceBinding::*BindingField);
template <BindingField bindingField1, BindingField bindingField2>
angle::Result BindResources2(spirv_cross::CompilerMSL *compiler,
                             const spirv_cross::SmallVector<spirv_cross::Resource> &resources,
                             gl::ShaderType shaderType)
{
    auto &compilerMsl = *compiler;

    for (const spirv_cross::Resource &resource : resources)
    {
        spirv_cross::MSLResourceBinding resBinding;
        resBinding.stage = ShaderTypeToSpvExecutionModel(shaderType);

        if (compilerMsl.has_decoration(resource.id, spv::DecorationDescriptorSet))
        {
            resBinding.desc_set =
                compilerMsl.get_decoration(resource.id, spv::DecorationDescriptorSet);
        }

        if (resBinding.desc_set != 0 ||
            !compilerMsl.has_decoration(resource.id, spv::DecorationBinding))
        {
            continue;
        }

        resBinding.binding        = compilerMsl.get_decoration(resource.id, spv::DecorationBinding);
        resBinding.*bindingField1 = resBinding.binding;
        if (bindingField1 != bindingField2)
        {
            resBinding.*bindingField2 = resBinding.binding;
        }

        compilerMsl.add_msl_resource_binding(resBinding);
    }

    return angle::Result::Continue;
}

template <BindingField bindingField>
angle::Result BindResources(spirv_cross::CompilerMSL *compiler,
                            const spirv_cross::SmallVector<spirv_cross::Resource> &resources,
                            gl::ShaderType shaderType)
{
    return BindResources2<bindingField, bindingField>(compiler, resources, shaderType);
}

// TODO(hqle): some of the code here are duplicated from Vulkan's ProgramMtl.cpp
// In future, we should move common code to a dedicated file
void InitDefaultUniformBlock(const std::vector<sh::Uniform> &uniforms,
                             gl::Shader *shader,
                             sh::BlockLayoutMap *blockLayoutMapOut,
                             size_t *blockSizeOut)
{
    if (uniforms.empty())
    {
        *blockSizeOut = 0;
        return;
    }

    sh::Std140BlockEncoder blockEncoder;
    sh::GetUniformBlockInfo(uniforms, "", &blockEncoder, blockLayoutMapOut);

    size_t blockSize = blockEncoder.getCurrentOffset();

    // TODO(jmadill): I think we still need a valid block for the pipeline even if zero sized.
    if (blockSize == 0)
    {
        *blockSizeOut = 0;
        return;
    }

    // Need to round up to multiple of vec4
    *blockSizeOut = roundUp(blockSize, static_cast<size_t>(16));
    return;
}

template <typename T>
void UpdateDefaultUniformBlock(GLsizei count,
                               uint32_t arrayIndex,
                               int componentCount,
                               const T *v,
                               const sh::BlockMemberInfo &layoutInfo,
                               angle::MemoryBuffer *uniformData)
{
    const int elementSize = sizeof(T) * componentCount;

    uint8_t *dst = uniformData->data() + layoutInfo.offset;
    if (layoutInfo.arrayStride == 0 || layoutInfo.arrayStride == elementSize)
    {
        uint32_t arrayOffset = arrayIndex * layoutInfo.arrayStride;
        uint8_t *writePtr    = dst + arrayOffset;
        ASSERT(writePtr + (elementSize * count) <= uniformData->data() + uniformData->size());
        memcpy(writePtr, v, elementSize * count);
    }
    else
    {
        // Have to respect the arrayStride between each element of the array.
        int maxIndex = arrayIndex + count;
        for (int writeIndex = arrayIndex, readIndex = 0; writeIndex < maxIndex;
             writeIndex++, readIndex++)
        {
            const int arrayOffset = writeIndex * layoutInfo.arrayStride;
            uint8_t *writePtr     = dst + arrayOffset;
            const T *readPtr      = v + (readIndex * componentCount);
            ASSERT(writePtr + elementSize <= uniformData->data() + uniformData->size());
            memcpy(writePtr, readPtr, elementSize);
        }
    }
}

template <typename T>
void ReadFromDefaultUniformBlock(int componentCount,
                                 uint32_t arrayIndex,
                                 T *dst,
                                 const sh::BlockMemberInfo &layoutInfo,
                                 const angle::MemoryBuffer *uniformData)
{
    ASSERT(layoutInfo.offset != -1);

    const int elementSize = sizeof(T) * componentCount;
    const uint8_t *source = uniformData->data() + layoutInfo.offset;

    if (layoutInfo.arrayStride == 0 || layoutInfo.arrayStride == elementSize)
    {
        const uint8_t *readPtr = source + arrayIndex * layoutInfo.arrayStride;
        memcpy(dst, readPtr, elementSize);
    }
    else
    {
        // Have to respect the arrayStride between each element of the array.
        const int arrayOffset  = arrayIndex * layoutInfo.arrayStride;
        const uint8_t *readPtr = source + arrayOffset;
        memcpy(dst, readPtr, elementSize);
    }
}

class Std140BlockLayoutEncoderFactory : public gl::CustomBlockLayoutEncoderFactory
{
  public:
    sh::BlockLayoutEncoder *makeEncoder() override { return new sh::Std140BlockEncoder(); }
};

}  // namespace

// ProgramMtl implementation
ProgramMtl::DefaultUniformBlock::DefaultUniformBlock() {}

ProgramMtl::DefaultUniformBlock::~DefaultUniformBlock() = default;

ProgramMtl::ProgramMtl(const gl::ProgramState &state) : ProgramImpl(state) {}

ProgramMtl::~ProgramMtl() {}

void ProgramMtl::destroy(const gl::Context *context)
{
    auto contextMtl = mtl::GetImpl(context);

    reset(contextMtl);
}

void ProgramMtl::reset(ContextMtl *context)
{
    for (auto &block : mDefaultUniformBlocks)
    {
        block.uniformLayout.clear();
    }

    mMetalRenderPipelineCache.clear();
}

std::unique_ptr<rx::LinkEvent> ProgramMtl::load(const gl::Context *context,
                                                gl::BinaryInputStream *stream,
                                                gl::InfoLog &infoLog)
{
    // TODO(hqle): support binary shader
    UNIMPLEMENTED();
    return std::make_unique<LinkEventDone>(angle::Result::Stop);
}

void ProgramMtl::save(const gl::Context *context, gl::BinaryOutputStream *stream)
{
    // TODO(hqle): support binary shader
    UNIMPLEMENTED();
}

void ProgramMtl::setBinaryRetrievableHint(bool retrievable)
{
    UNIMPLEMENTED();
}

void ProgramMtl::setSeparable(bool separable)
{
    UNIMPLEMENTED();
}

std::unique_ptr<LinkEvent> ProgramMtl::link(const gl::Context *context,
                                            const gl::ProgramLinkedResources &resources,
                                            gl::InfoLog &infoLog)
{
    // Link resources before calling GetShaderSource to make sure they are ready for the set/binding
    // assignment done in that function.
    linkResources(resources);

    GlslangWrapperMtl::GetShaderSource(mState, resources, &mShaderSource[gl::ShaderType::Vertex],
                                       &mShaderSource[gl::ShaderType::Fragment]);

    // TODO(hqle): Parallelize linking.
    return std::make_unique<LinkEventDone>(linkImpl(context, infoLog));
}

angle::Result ProgramMtl::linkImpl(const gl::Context *glContext, gl::InfoLog &infoLog)
{
    ContextMtl *contextMtl = mtl::GetImpl(glContext);
    // TODO(hqle): No transform feedbacks for now, since we only support ES 2.0 atm

    reset(contextMtl);

    ANGLE_TRY(initDefaultUniformBlocks(glContext));

    // Convert GLSL to spirv code
    std::vector<uint32_t> vertexCode;
    std::vector<uint32_t> fragmentCode;
    ANGLE_TRY(GlslangWrapperMtl::GetShaderCode(
        contextMtl, contextMtl->getCaps(), false, mShaderSource[gl::ShaderType::Vertex],
        mShaderSource[gl::ShaderType::Fragment], &vertexCode, &fragmentCode));

    // Convert spirv code to MSL
    ANGLE_TRY(convertToMsl(glContext, gl::ShaderType::Vertex, infoLog, &vertexCode));
    ANGLE_TRY(convertToMsl(glContext, gl::ShaderType::Fragment, infoLog, &fragmentCode));

    return angle::Result::Continue;
}

void ProgramMtl::linkResources(const gl::ProgramLinkedResources &resources)
{
    Std140BlockLayoutEncoderFactory std140EncoderFactory;
    gl::ProgramLinkedResourcesLinker linker(&std140EncoderFactory);

    linker.linkResources(mState, resources);
}

angle::Result ProgramMtl::initDefaultUniformBlocks(const gl::Context *glContext)
{
    ContextMtl *contextMtl = mtl::GetImpl(glContext);

    // Process vertex and fragment uniforms into std140 packing.
    gl::ShaderMap<sh::BlockLayoutMap> layoutMap;
    gl::ShaderMap<size_t> requiredBufferSize;
    requiredBufferSize.fill(0);

    for (gl::ShaderType shaderType : gl::AllGLES2ShaderTypes())
    {
        gl::Shader *shader = mState.getAttachedShader(shaderType);
        if (shader)
        {
            const std::vector<sh::Uniform> &uniforms = shader->getUniforms();
            InitDefaultUniformBlock(uniforms, shader, &layoutMap[shaderType],
                                    &requiredBufferSize[shaderType]);
        }
    }

    // Init the default block layout info.
    const auto &uniforms         = mState.getUniforms();
    const auto &uniformLocations = mState.getUniformLocations();
    for (size_t locSlot = 0; locSlot < uniformLocations.size(); ++locSlot)
    {
        const gl::VariableLocation &location = uniformLocations[locSlot];
        gl::ShaderMap<sh::BlockMemberInfo> layoutInfo;

        if (location.used() && !location.ignored)
        {
            const gl::LinkedUniform &uniform = uniforms[location.index];
            if (uniform.isInDefaultBlock() && !uniform.isSampler())
            {
                std::string uniformName = uniform.name;
                if (uniform.isArray())
                {
                    // Gets the uniform name without the [0] at the end.
                    uniformName = gl::ParseResourceName(uniformName, nullptr);
                }

                bool found = false;

                for (gl::ShaderType shaderType : gl::AllGLES2ShaderTypes())
                {
                    auto it = layoutMap[shaderType].find(uniformName);
                    if (it != layoutMap[shaderType].end())
                    {
                        found                  = true;
                        layoutInfo[shaderType] = it->second;
                    }
                }

                ASSERT(found);
            }
        }

        for (gl::ShaderType shaderType : gl::AllGLES2ShaderTypes())
        {
            mDefaultUniformBlocks[shaderType].uniformLayout.push_back(layoutInfo[shaderType]);
        }
    }

    for (gl::ShaderType shaderType : gl::AllGLES2ShaderTypes())
    {
        if (requiredBufferSize[shaderType] > 0)
        {
            ASSERT(requiredBufferSize[shaderType] <= kDefaultUniformsMaxSize);

            if (!mDefaultUniformBlocks[shaderType].uniformData.resize(
                    requiredBufferSize[shaderType]))
            {
                ANGLE_MTL_CHECK_WITH_ERR(contextMtl, false, GL_OUT_OF_MEMORY);
            }

            // Initialize uniform buffer memory to zero by default.
            mDefaultUniformBlocks[shaderType].uniformData.fill(0);
            mDefaultUniformBlocksDirty.set(shaderType);
        }
    }

    return angle::Result::Continue;
}

angle::Result ProgramMtl::convertToMsl(const gl::Context *glContext,
                                       gl::ShaderType shaderType,
                                       gl::InfoLog &infoLog,
                                       std::vector<uint32_t> *sprivCode)
{
    ContextMtl *contextMtl = mtl::GetImpl(glContext);

    spirv_cross::CompilerMSL compilerMsl(std::move(*sprivCode));

    spirv_cross::CompilerMSL::Options compOpt;
#if TARGET_OS_OSX
    compOpt.platform = spirv_cross::CompilerMSL::Options::macOS;
#else
    compOpt.platform = spirv_cross::CompilerMSL::Options::iOS;
#endif

    if (@available(macOS 10.14, iOS 12, *))
    {
        // Use Metal 2.1
        compOpt.set_msl_version(2, 1);
    }
    else
    {
        // Always use at least Metal 2.0.
        compOpt.set_msl_version(2);
    }

    compilerMsl.set_msl_options(compOpt);

    // Tell spirv-cross to map default & driver uniform blocks & samplers as we want
    spirv_cross::ShaderResources mslRes = compilerMsl.get_shader_resources();

    ANGLE_TRY(BindResources<&spirv_cross::MSLResourceBinding::msl_buffer>(
        &compilerMsl, mslRes.uniform_buffers, shaderType));

    auto bindingErr = BindResources2<&spirv_cross::MSLResourceBinding::msl_sampler,
                                     &spirv_cross::MSLResourceBinding::msl_texture>(
        &compilerMsl, mslRes.sampled_images, shaderType);
    ANGLE_MTL_CHECK(contextMtl, !IsError(bindingErr));

    // TODO(hqle): spirv-cross uses exceptions to report error, what should we do here
    // in case of error?
    std::string translatedMsl = compilerMsl.compile();
    if (translatedMsl.size() == 0)
    {
        ANGLE_MTL_CHECK_WITH_ERR(contextMtl, false, GL_INVALID_OPERATION);
    }

    // Create actual Metal shader
    ANGLE_TRY(createMslShader(glContext, shaderType, infoLog, translatedMsl));

    return angle::Result::Continue;
}

angle::Result ProgramMtl::createMslShader(const gl::Context *glContext,
                                          gl::ShaderType shaderType,
                                          gl::InfoLog &infoLog,
                                          const std::string &translatedMsl)
{
    ANGLE_MTL_OBJC_SCOPE
    {
        ContextMtl *contextMtl  = mtl::GetImpl(glContext);
        RendererMtl *renderer   = contextMtl->getRenderer();
        id<MTLDevice> mtlDevice = renderer->getMetalDevice();

        // Convert to actual binary shader
        mtl::AutoObjCPtr<NSError *> err = nil;
        mtl::AutoObjCPtr<id<MTLLibrary>> mtlShaderLib =
            mtl::CreateShaderLibrary(mtlDevice, translatedMsl, &err);
        if (err && !mtlShaderLib)
        {
            std::ostringstream ss;
            ss << "Internal error compiling Metal shader:\n"
               << err.get().localizedDescription.UTF8String << "\n";

            ERR() << ss.str();

            infoLog << ss.str();

            ANGLE_MTL_CHECK_WITH_ERR(contextMtl, false, GL_INVALID_OPERATION);
        }

        auto mtlShader = [mtlShaderLib.get() newFunctionWithName:SHADER_ENTRY_NAME];
        ASSERT(mtlShader);
        if (shaderType == gl::ShaderType::Vertex)
        {
            mMetalRenderPipelineCache.setVertexShader(contextMtl, mtlShader);
        }
        else if (shaderType == gl::ShaderType::Fragment)
        {
            mMetalRenderPipelineCache.setFragmentShader(contextMtl, mtlShader);
        }

        return angle::Result::Continue;
    }
}

GLboolean ProgramMtl::validate(const gl::Caps &caps, gl::InfoLog *infoLog)
{
    // No-op. The spec is very vague about the behavior of validation.
    return GL_TRUE;
}

template <typename T>
void ProgramMtl::setUniformImpl(GLint location, GLsizei count, const T *v, GLenum entryPointType)
{
    const gl::VariableLocation &locationInfo = mState.getUniformLocations()[location];
    const gl::LinkedUniform &linkedUniform   = mState.getUniforms()[locationInfo.index];

    if (linkedUniform.isSampler())
    {
        // We already handle this in super class
        return;
    }

    if (linkedUniform.typeInfo->type == entryPointType)
    {
        for (gl::ShaderType shaderType : gl::AllGLES2ShaderTypes())
        {
            DefaultUniformBlock &uniformBlock     = mDefaultUniformBlocks[shaderType];
            const sh::BlockMemberInfo &layoutInfo = uniformBlock.uniformLayout[location];

            // Assume an offset of -1 means the block is unused.
            if (layoutInfo.offset == -1)
            {
                continue;
            }

            const GLint componentCount = linkedUniform.typeInfo->componentCount;
            UpdateDefaultUniformBlock(count, locationInfo.arrayIndex, componentCount, v, layoutInfo,
                                      &uniformBlock.uniformData);
            mDefaultUniformBlocksDirty.set(shaderType);
        }
    }
    else
    {
        for (gl::ShaderType shaderType : gl::AllGLES2ShaderTypes())
        {
            DefaultUniformBlock &uniformBlock     = mDefaultUniformBlocks[shaderType];
            const sh::BlockMemberInfo &layoutInfo = uniformBlock.uniformLayout[location];

            // Assume an offset of -1 means the block is unused.
            if (layoutInfo.offset == -1)
            {
                continue;
            }

            const GLint componentCount = linkedUniform.typeInfo->componentCount;

            ASSERT(linkedUniform.typeInfo->type == gl::VariableBoolVectorType(entryPointType));

            GLint initialArrayOffset =
                locationInfo.arrayIndex * layoutInfo.arrayStride + layoutInfo.offset;
            for (GLint i = 0; i < count; i++)
            {
                GLint elementOffset = i * layoutInfo.arrayStride + initialArrayOffset;
                GLint *dest =
                    reinterpret_cast<GLint *>(uniformBlock.uniformData.data() + elementOffset);
                const T *source = v + i * componentCount;

                for (int c = 0; c < componentCount; c++)
                {
                    dest[c] = (source[c] == static_cast<T>(0)) ? GL_FALSE : GL_TRUE;
                }
            }

            mDefaultUniformBlocksDirty.set(shaderType);
        }
    }
}

template <typename T>
void ProgramMtl::getUniformImpl(GLint location, T *v, GLenum entryPointType) const
{
    const gl::VariableLocation &locationInfo = mState.getUniformLocations()[location];
    const gl::LinkedUniform &linkedUniform   = mState.getUniforms()[locationInfo.index];

    ASSERT(!linkedUniform.isSampler());

    const gl::ShaderType shaderType = linkedUniform.getFirstShaderTypeWhereActive();
    ASSERT(shaderType != gl::ShaderType::InvalidEnum);

    const DefaultUniformBlock &uniformBlock = mDefaultUniformBlocks[shaderType];
    const sh::BlockMemberInfo &layoutInfo   = uniformBlock.uniformLayout[location];

    ASSERT(linkedUniform.typeInfo->componentType == entryPointType ||
           linkedUniform.typeInfo->componentType == gl::VariableBoolVectorType(entryPointType));

    if (gl::IsMatrixType(linkedUniform.type))
    {
        const uint8_t *ptrToElement = uniformBlock.uniformData.data() + layoutInfo.offset +
                                      (locationInfo.arrayIndex * layoutInfo.arrayStride);
        GetMatrixUniform(linkedUniform.type, v, reinterpret_cast<const T *>(ptrToElement), false);
    }
    else
    {
        ReadFromDefaultUniformBlock(linkedUniform.typeInfo->componentCount, locationInfo.arrayIndex,
                                    v, layoutInfo, &uniformBlock.uniformData);
    }
}

void ProgramMtl::setUniform1fv(GLint location, GLsizei count, const GLfloat *v)
{
    setUniformImpl(location, count, v, GL_FLOAT);
}

void ProgramMtl::setUniform2fv(GLint location, GLsizei count, const GLfloat *v)
{
    setUniformImpl(location, count, v, GL_FLOAT_VEC2);
}

void ProgramMtl::setUniform3fv(GLint location, GLsizei count, const GLfloat *v)
{
    setUniformImpl(location, count, v, GL_FLOAT_VEC3);
}

void ProgramMtl::setUniform4fv(GLint location, GLsizei count, const GLfloat *v)
{
    setUniformImpl(location, count, v, GL_FLOAT_VEC4);
}

void ProgramMtl::setUniform1iv(GLint startLocation, GLsizei count, const GLint *v)
{
    setUniformImpl(startLocation, count, v, GL_INT);
}

void ProgramMtl::setUniform2iv(GLint location, GLsizei count, const GLint *v)
{
    setUniformImpl(location, count, v, GL_INT_VEC2);
}

void ProgramMtl::setUniform3iv(GLint location, GLsizei count, const GLint *v)
{
    setUniformImpl(location, count, v, GL_INT_VEC3);
}

void ProgramMtl::setUniform4iv(GLint location, GLsizei count, const GLint *v)
{
    setUniformImpl(location, count, v, GL_INT_VEC4);
}

void ProgramMtl::setUniform1uiv(GLint location, GLsizei count, const GLuint *v)
{
    setUniformImpl(location, count, v, GL_UNSIGNED_INT);
}

void ProgramMtl::setUniform2uiv(GLint location, GLsizei count, const GLuint *v)
{
    setUniformImpl(location, count, v, GL_UNSIGNED_INT_VEC2);
}

void ProgramMtl::setUniform3uiv(GLint location, GLsizei count, const GLuint *v)
{
    setUniformImpl(location, count, v, GL_UNSIGNED_INT_VEC3);
}

void ProgramMtl::setUniform4uiv(GLint location, GLsizei count, const GLuint *v)
{
    setUniformImpl(location, count, v, GL_UNSIGNED_INT_VEC4);
}

template <int cols, int rows>
void ProgramMtl::setUniformMatrixfv(GLint location,
                                    GLsizei count,
                                    GLboolean transpose,
                                    const GLfloat *value)
{
    const gl::VariableLocation &locationInfo = mState.getUniformLocations()[location];
    const gl::LinkedUniform &linkedUniform   = mState.getUniforms()[locationInfo.index];

    for (gl::ShaderType shaderType : gl::AllGLES2ShaderTypes())
    {
        DefaultUniformBlock &uniformBlock     = mDefaultUniformBlocks[shaderType];
        const sh::BlockMemberInfo &layoutInfo = uniformBlock.uniformLayout[location];

        // Assume an offset of -1 means the block is unused.
        if (layoutInfo.offset == -1)
        {
            continue;
        }

        bool updated = SetFloatUniformMatrixGLSL<cols, rows>(
            locationInfo.arrayIndex, linkedUniform.getArraySizeProduct(), count, transpose, value,
            uniformBlock.uniformData.data() + layoutInfo.offset);

        // If the uniformsDirty flag was true, we don't want to flip it to false here if the
        // setter did not update any data. We still want the uniform to be included when we'll
        // update the descriptor sets.
        if (updated)
        {
            mDefaultUniformBlocksDirty.set(shaderType);
        }
    }
}

void ProgramMtl::setUniformMatrix2fv(GLint location,
                                     GLsizei count,
                                     GLboolean transpose,
                                     const GLfloat *value)
{
    setUniformMatrixfv<2, 2>(location, count, transpose, value);
}

void ProgramMtl::setUniformMatrix3fv(GLint location,
                                     GLsizei count,
                                     GLboolean transpose,
                                     const GLfloat *value)
{
    setUniformMatrixfv<3, 3>(location, count, transpose, value);
}

void ProgramMtl::setUniformMatrix4fv(GLint location,
                                     GLsizei count,
                                     GLboolean transpose,
                                     const GLfloat *value)
{
    setUniformMatrixfv<4, 4>(location, count, transpose, value);
}

void ProgramMtl::setUniformMatrix2x3fv(GLint location,
                                       GLsizei count,
                                       GLboolean transpose,
                                       const GLfloat *value)
{
    setUniformMatrixfv<2, 3>(location, count, transpose, value);
}

void ProgramMtl::setUniformMatrix3x2fv(GLint location,
                                       GLsizei count,
                                       GLboolean transpose,
                                       const GLfloat *value)
{
    setUniformMatrixfv<3, 2>(location, count, transpose, value);
}

void ProgramMtl::setUniformMatrix2x4fv(GLint location,
                                       GLsizei count,
                                       GLboolean transpose,
                                       const GLfloat *value)
{
    setUniformMatrixfv<2, 4>(location, count, transpose, value);
}

void ProgramMtl::setUniformMatrix4x2fv(GLint location,
                                       GLsizei count,
                                       GLboolean transpose,
                                       const GLfloat *value)
{
    setUniformMatrixfv<4, 2>(location, count, transpose, value);
}

void ProgramMtl::setUniformMatrix3x4fv(GLint location,
                                       GLsizei count,
                                       GLboolean transpose,
                                       const GLfloat *value)
{
    setUniformMatrixfv<3, 4>(location, count, transpose, value);
}

void ProgramMtl::setUniformMatrix4x3fv(GLint location,
                                       GLsizei count,
                                       GLboolean transpose,
                                       const GLfloat *value)
{
    setUniformMatrixfv<4, 3>(location, count, transpose, value);
}

void ProgramMtl::setPathFragmentInputGen(const std::string &inputName,
                                         GLenum genMode,
                                         GLint components,
                                         const GLfloat *coeffs)
{
    UNIMPLEMENTED();
}

void ProgramMtl::getUniformfv(const gl::Context *context, GLint location, GLfloat *params) const
{
    getUniformImpl(location, params, GL_FLOAT);
}

void ProgramMtl::getUniformiv(const gl::Context *context, GLint location, GLint *params) const
{
    getUniformImpl(location, params, GL_INT);
}

void ProgramMtl::getUniformuiv(const gl::Context *context, GLint location, GLuint *params) const
{
    getUniformImpl(location, params, GL_UNSIGNED_INT);
}

angle::Result ProgramMtl::setupDraw(const gl::Context *glContext,
                                    mtl::RenderCommandEncoder *cmdEncoder,
                                    const Optional<mtl::RenderPipelineDesc> &changedPipelineDescOpt,
                                    bool forceTexturesSetting)
{
    ContextMtl *context = mtl::GetImpl(glContext);
    if (changedPipelineDescOpt.valid())
    {
        const auto &changedPipelineDesc = changedPipelineDescOpt.value();
        // Render pipeline state needs to be changed
        id<MTLRenderPipelineState> pipelineState =
            mMetalRenderPipelineCache.getRenderPipelineState(context, changedPipelineDesc);
        if (!pipelineState)
        {
            // Error already logged inside getRenderPipelineState()
            return angle::Result::Stop;
        }
        cmdEncoder->setRenderPipelineState(pipelineState);

        // We need to rebind uniform buffers & textures also
        mDefaultUniformBlocksDirty.set();
        mSamplerBindingsDirty.set();
    }

    ANGLE_TRY(commitUniforms(context, cmdEncoder));
    ANGLE_TRY(updateTextures(glContext, cmdEncoder, forceTexturesSetting));

    return angle::Result::Continue;
}

angle::Result ProgramMtl::commitUniforms(ContextMtl *context, mtl::RenderCommandEncoder *cmdEncoder)
{
    for (gl::ShaderType shaderType : gl::AllGLES2ShaderTypes())
    {
        if (!mDefaultUniformBlocksDirty[shaderType])
        {
            continue;
        }
        DefaultUniformBlock &uniformBlock = mDefaultUniformBlocks[shaderType];

        if (!uniformBlock.uniformData.size())
        {
            continue;
        }
        switch (shaderType)
        {
            case gl::ShaderType::Vertex:
                cmdEncoder->setVertexBytes(uniformBlock.uniformData.data(),
                                           uniformBlock.uniformData.size(),
                                           kDefaultUniformsBindingIndex);
                break;
            case gl::ShaderType::Fragment:
                cmdEncoder->setFragmentBytes(uniformBlock.uniformData.data(),
                                             uniformBlock.uniformData.size(),
                                             kDefaultUniformsBindingIndex);
                break;
            default:
                UNREACHABLE();
        }

        mDefaultUniformBlocksDirty.reset(shaderType);
    }

    return angle::Result::Continue;
}

angle::Result ProgramMtl::updateTextures(const gl::Context *glContext,
                                         mtl::RenderCommandEncoder *cmdEncoder,
                                         bool forceUpdate)
{
    const auto &glState = glContext->getState();

    const gl::ActiveTexturePointerArray &completeTextures = glState.getActiveTexturesCache();

    for (gl::ShaderType shaderType : gl::AllGLES2ShaderTypes())
    {
        if (!mSamplerBindingsDirty[shaderType] && !forceUpdate)
        {
            continue;
        }

        for (uint32_t textureIndex = 0; textureIndex < mState.getSamplerBindings().size();
             ++textureIndex)
        {
            const gl::SamplerBinding &samplerBinding = mState.getSamplerBindings()[textureIndex];

            ASSERT(!samplerBinding.unreferenced);

            for (uint32_t arrayElement = 0; arrayElement < samplerBinding.boundTextureUnits.size();
                 ++arrayElement)
            {
                GLuint textureUnit   = samplerBinding.boundTextureUnits[arrayElement];
                gl::Texture *texture = completeTextures[textureUnit];
                if (!texture)
                {
                    continue;
                }

                TextureMtl *textureMtl = mtl::GetImpl(texture);
                auto destBindingPoint  = textureIndex + arrayElement;

                switch (shaderType)
                {
                    case gl::ShaderType::Vertex:
                        textureMtl->bindVertexShader(glContext, cmdEncoder, destBindingPoint,
                                                     destBindingPoint);
                        break;
                    case gl::ShaderType::Fragment:
                        textureMtl->bindFragmentShader(glContext, cmdEncoder, destBindingPoint,
                                                       destBindingPoint);
                        break;
                    default:
                        UNREACHABLE();
                }
            }  // for array elements
        }      // for sampler bindings
    }          // for shader types

    return angle::Result::Continue;
}

}  // namespace rx
