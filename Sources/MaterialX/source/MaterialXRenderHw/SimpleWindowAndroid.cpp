//
// Copyright Contributors to the MaterialX Project
// SPDX-License-Identifier: Apache-2.0
//

#if defined(__ANDROID__)

#include <MaterialX/MXRenderHwSimpleWindow.h>

MATERIALX_NAMESPACE_BEGIN

// Android has no native X11/Cocoa window system for offline MaterialX rendering.
// These are intentional no-op stubs; actual rendering is driven by the Android
// runtime (GLSurfaceView / ANativeActivity) via EGL.

SimpleWindow::SimpleWindow() : _width(0), _height(0)
{
  static unsigned int windowCount = 1;
  _id = windowCount;
  windowCount++;
}

bool SimpleWindow::initialize(const char * /*title*/,
                              unsigned int  width,
                              unsigned int  height,
                              void * /*applicationShell*/)
{
  _width  = width;
  _height = height;
  _windowWrapper = WindowWrapper::create(nullptr);
  return true;
}

SimpleWindow::~SimpleWindow() {}

MATERIALX_NAMESPACE_END

#endif // defined(__ANDROID__)
