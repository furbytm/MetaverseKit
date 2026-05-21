//
// Copyright Contributors to the MaterialX Project
// SPDX-License-Identifier: Apache-2.0
//

#import <Foundation/Foundation.h>

#include <MaterialX/MXGenShaderHwShaderGenerator.h>
#include <MaterialX/MXRenderHwSimpleWindow.h>
#include <MaterialX/MXRenderMslRenderer.h>
#include <MaterialX/MXRenderTinyObjLoader.h>

#include <iostream>

#import <Metal/Metal.h>

MATERIALX_NAMESPACE_BEGIN

//
// MslRenderer methods
//

MslRendererPtr MslRenderer::create(unsigned int width, unsigned int height,
                                   Image::BaseType baseType) {
  return MslRendererPtr(new MslRenderer(width, height, baseType));
}

id<MTLDevice> MslRenderer::getMetalDevice() const { return _device; }

MslRenderer::MslRenderer(unsigned int width, unsigned int height,
                         Image::BaseType baseType)
    : ShaderRenderer(width, height, baseType, MatrixConvention::Metal),
      _initialized(false), _screenColor(DEFAULT_SCREEN_COLOR_LIN_REC709) {
  _program = MslProgram::create();

  _geometryHandler = GeometryHandler::create();
  _geometryHandler->addLoader(TinyObjLoader::create());
}

void MslRenderer::initialize(RenderContextHandle) {
  if (!_initialized) {
    // Create window
    _window = SimpleWindow::create();

    if (!_window->initialize("Renderer Window", _width, _height, nullptr)) {
      throw ExceptionRenderError("Failed to initialize renderer window");
    }

    _device = MTLCreateSystemDefaultDevice();
    _cmdQueue = [_device newCommandQueue];
    createFrameBuffer(true);

    _initialized = true;
  }
}

void MslRenderer::createProgram(ShaderPtr shader) {
  _program = MslProgram::create();
  _program->setStages(shader);
  _program->build(_device, _framebuffer);
}

void MslRenderer::createProgram(const StageMap &stages) {
  for (const auto &it : stages) {
    _program->addStage(it.first, it.second);
  }
  _program->build(_device, _framebuffer);
}

void MslRenderer::renderTextureSpace(const Vector2 &uvMin,
                                     const Vector2 &uvMax) {
  bool captureRenderTextureSpace = false;
  if (captureRenderTextureSpace)
    triggerProgrammaticCapture();

  MTLRenderPassDescriptor *desc = [[MTLRenderPassDescriptor alloc] init];
  _framebuffer->bind(desc);

  _cmdBuffer = [_cmdQueue commandBuffer];

  id<MTLRenderCommandEncoder> rendercmdEncoder =
      [_cmdBuffer renderCommandEncoderWithDescriptor:(desc)];
  _program->bind(rendercmdEncoder);
  _program->prepareUsedResources(rendercmdEncoder, _camera, _geometryHandler,
                                 _imageHandler, _lightHandler);

  MeshPtr mesh = _geometryHandler->createQuadMesh(uvMin, uvMax, true);
  _program->bindMesh(rendercmdEncoder, mesh);
  MeshPartitionPtr part = mesh->getPartition(0);
  _program->bindPartition(part);
  MeshIndexBuffer &indexData = part->getIndices();
  [rendercmdEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                               indexCount:indexData.size()
                                indexType:MTLIndexTypeUInt32
                              indexBuffer:_program->getIndexBuffer(part)
                        indexBufferOffset:0];

  _framebuffer->unbind();
  [rendercmdEncoder endEncoding];

  [_cmdBuffer commit];
  [_cmdBuffer waitUntilCompleted];

#if !__has_feature(objc_arc)
  [desc release];
#endif // !__has_feature(objc_arc)

  if (captureRenderTextureSpace)
    stopProgrammaticCapture();
}

void MslRenderer::validateInputs() {
  // Check that the generated uniforms and attributes are valid
  _program->getUniformsList();
  _program->getAttributesList();
}

void MslRenderer::updateUniform(const string &name, ConstValuePtr value) {
  _program->bindUniform(name, value);
}

void MslRenderer::createFrameBuffer(bool encodeSrgb) {
  _framebuffer = MetalFramebuffer::create(_device, _width, _height, 4,
                                          _baseType, nil, encodeSrgb);
}

void MslRenderer::setSize(unsigned int width, unsigned int height) {
  if (_framebuffer) {
    _framebuffer->resize(width, height);
  } else {
    _width = width;
    _height = height;
    createFrameBuffer(true);
  }
}

void MslRenderer::triggerProgrammaticCapture() {
  MTLCaptureManager *captureManager = [MTLCaptureManager sharedCaptureManager];
  MTLCaptureDescriptor *captureDescriptor = [[MTLCaptureDescriptor alloc] init];
  [captureDescriptor setCaptureObject:_device];

  NSError *error = nil;
  if (![captureManager startCaptureWithDescriptor:captureDescriptor
                                            error:&error]) {
#if WITH_APPLE_NSLOG
    NS::Log(NSString::string("Failed to start capture, error %@", error),
            NS::UTF8StringEncoding);
#endif /* WITH_APPLE_NSLOG */
  }
}

void MslRenderer::stopProgrammaticCapture() {
  MTLCaptureManager *captureManager = [MTLCaptureManager sharedCaptureManager];
  [captureManager stopCapture];
}

void MslRenderer::render() {
  bool captureFrame = false;
  if (captureFrame)
    triggerProgrammaticCapture();

  _cmdBuffer = [_cmdQueue commandBuffer];
  MTLRenderPassDescriptor *renderpassDesc =
      [[MTLRenderPassDescriptor alloc] init];

  _framebuffer->bind(renderpassDesc);
  [[renderpassDesc colorAttachments][0]
      setClearColor:MTLClearColorMake(_screenColor[0], _screenColor[1],
                                      _screenColor[2], 1.0f)];

  id<MTLRenderCommandEncoder> renderCmdEncoder =
      [_cmdBuffer renderCommandEncoderWithDescriptor:renderpassDesc];

  MTLDepthStencilDescriptor *depthStencilDesc =
      [[MTLDepthStencilDescriptor alloc] init];
  [depthStencilDesc setDepthWriteEnabled:!(_program->isTransparent())];
  [depthStencilDesc setDepthCompareFunction:(MTLCompareFunctionLess)];

  id<MTLDepthStencilState> depthStencilState =
      [_device newDepthStencilStateWithDescriptor:(depthStencilDesc)];
  [renderCmdEncoder setDepthStencilState:(depthStencilState)];
  [renderCmdEncoder setCullMode:(MTLCullModeBack)];

  try {
    // Bind program and input parameters
    if (_program) {
      // Bind the program to use
      _program->bind(renderCmdEncoder);
      _program->prepareUsedResources(renderCmdEncoder, _camera,
                                     _geometryHandler, _imageHandler,
                                     _lightHandler);

      // Draw all the partitions of all the meshes in the handler
      for (const auto &mesh : _geometryHandler->getMeshes()) {
        _program->bindMesh(renderCmdEncoder, mesh);

        for (size_t i = 0; i < mesh->getPartitionCount(); i++) {
          auto part = mesh->getPartition(i);
          _program->bindPartition(part);
          MeshIndexBuffer &indexData = part->getIndices();

          if (_program->isTransparent()) {
            [renderCmdEncoder setCullMode:(MTLCullModeFront)];
            [renderCmdEncoder
                drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                           indexCount:(int)indexData.size()
                            indexType:MTLIndexTypeUInt32
                          indexBuffer:(_program->getIndexBuffer(
                                          part))indexBufferOffset:0];
            [renderCmdEncoder setCullMode:(MTLCullModeBack)];
          }

          [renderCmdEncoder
              drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                         indexCount:(int)indexData.size()
                          indexType:MTLIndexTypeUInt32
                        indexBuffer:(_program->getIndexBuffer(
                                        part))indexBufferOffset:0];
        }
      }
    }
  } catch (ExceptionRenderError &e) {
    _framebuffer->unbind();
    throw e;
  }

  [renderCmdEncoder endEncoding];

  _framebuffer->unbind();

  [_cmdBuffer commit];
  [_cmdBuffer waitUntilCompleted];

#if !__has_feature(objc_arc)
  [_cmdBuffer release];
#endif // __has_feature(objc_arc)
  _cmdBuffer = nil;

  if (captureFrame)
    stopProgrammaticCapture();
}

ImagePtr MslRenderer::captureImage(ImagePtr image) {
  return _framebuffer->getColorImage(_cmdQueue, image);
}

MATERIALX_NAMESPACE_END
