/**************************************************************************/
/*  metal_device_properties.mm                                            */
/**************************************************************************/
/*                         This file is part of:                          */
/*                             GODOT ENGINE                               */
/*                        https://godotengine.org                         */
/**************************************************************************/
/* Copyright (c) 2014-present Godot Engine contributors (see AUTHORS.md). */
/* Copyright (c) 2007-2014 Juan Linietsky, Ariel Manzur.                  */
/*                                                                        */
/* Permission is hereby granted, free of charge, to any person obtaining  */
/* a copy of this software and associated documentation files (the        */
/* "Software"), to deal in the Software without restriction, including    */
/* without limitation the rights to use, copy, modify, merge, publish,    */
/* distribute, sublicense, and/or sell copies of the Software, and to     */
/* permit persons to whom the Software is furnished to do so, subject to  */
/* the following conditions:                                              */
/*                                                                        */
/* The above copyright notice and this permission notice shall be         */
/* included in all copies or substantial portions of the Software.        */
/*                                                                        */
/* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,        */
/* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF     */
/* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. */
/* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY   */
/* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,   */
/* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE      */
/* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.                 */
/**************************************************************************/

/**************************************************************************/
/*                                                                        */
/* Portions of this code were derived from MoltenVK.                      */
/*                                                                        */
/* Copyright (c) 2015-2023 The Brenwill Workshop Ltd.                     */
/* (http://www.brenwill.com)                                              */
/*                                                                        */
/* Licensed under the Apache License, Version 2.0 (the "License");        */
/* you may not use this file except in compliance with the License.       */
/* You may obtain a copy of the License at                                */
/*                                                                        */
/*     http://www.apache.org/licenses/LICENSE-2.0                         */
/*                                                                        */
/* Unless required by applicable law or agreed to in writing, software    */
/* distributed under the License is distributed on an "AS IS" BASIS,      */
/* WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or        */
/* implied. See the License for the specific language governing           */
/* permissions and limitations under the License.                         */
/**************************************************************************/

#import "metal_device_properties.h"

#include "servers/rendering/renderer_rd/effects/metal_fx.h"

#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <spirv_cross.hpp>
#import <spirv_msl.hpp>

// Common scaling multipliers.
#define KIBI (1024)
#define MEBI (KIBI * KIBI)

#if (TARGET_OS_OSX && __MAC_OS_X_VERSION_MAX_ALLOWED < 140000) || (TARGET_OS_IPHONE && __IPHONE_OS_VERSION_MAX_ALLOWED < 170000)
#define MTLGPUFamilyApple9 (MTLGPUFamily)1009
#endif

API_AVAILABLE(macos(11.0), ios(14.0), tvos(14.0), visionos(1.0))
MTLGPUFamily &operator--(MTLGPUFamily &p_family) {
	p_family = static_cast<MTLGPUFamily>(static_cast<int>(p_family) - 1);
	if (p_family < MTLGPUFamilyApple1) {
		p_family = MTLGPUFamilyApple9;
	}

	return p_family;
}

void MetalDeviceProperties::init_features(id<MTLDevice> p_device) {
	features = {};

	features.highestFamily = MTLGPUFamilyApple1;
	for (MTLGPUFamily family = MTLGPUFamilyApple9; family >= MTLGPUFamilyApple1; --family) {
		if ([p_device supportsFamily:family]) {
			features.highestFamily = family;
			break;
		}
	}

	if (@available(macOS 11, iOS 16.4, tvOS 16.4, *)) {
		features.supportsBCTextureCompression = p_device.supportsBCTextureCompression;
	} else {
		features.supportsBCTextureCompression = false;
	}

#if TARGET_OS_OSX
	features.supportsDepth24Stencil8 = p_device.isDepth24Stencil8PixelFormatSupported;
#endif

	if (@available(macOS 11.0, iOS 14.0, tvOS 14.0, *)) {
		features.supports32BitFloatFiltering = p_device.supports32BitFloatFiltering;
		features.supports32BitMSAA = p_device.supports32BitMSAA;
	}

	if (@available(macOS 13.0, iOS 16.0, tvOS 16.0, *)) {
		features.supports_gpu_address = true;
	}

	features.hostMemoryPageSize = sysconf(_SC_PAGESIZE);

	for (SampleCount sc = SampleCount1; sc <= SampleCount64; sc <<= 1) {
		if ([p_device supportsTextureSampleCount:sc]) {
			features.supportedSampleCounts |= sc;
		}
	}

	features.layeredRendering = [p_device supportsFamily:MTLGPUFamilyApple5];
	features.multisampleLayeredRendering = [p_device supportsFamily:MTLGPUFamilyApple7];
	features.tessellationShader = [p_device supportsFamily:MTLGPUFamilyApple3];
	features.imageCubeArray = [p_device supportsFamily:MTLGPUFamilyApple3];
	features.quadPermute = [p_device supportsFamily:MTLGPUFamilyApple4];
	features.simdPermute = [p_device supportsFamily:MTLGPUFamilyApple6];
	features.simdReduction = [p_device supportsFamily:MTLGPUFamilyApple7];
	features.argument_buffers_tier = p_device.argumentBuffersSupport;
	features.supports_image_atomic_32_bit = [p_device supportsFamily:MTLGPUFamilyApple6];
	features.supports_image_atomic_64_bit = [p_device supportsFamily:MTLGPUFamilyApple9] || ([p_device supportsFamily:MTLGPUFamilyApple8] && [p_device supportsFamily:MTLGPUFamilyMac2]);
	if (@available(macOS 14.0, iOS 17.0, tvOS 17.0, visionOS 1.0, *)) {
		features.supports_native_image_atomics = true;
	}
	if (OS::get_singleton()->get_environment("GODOT_MTL_DISABLE_IMAGE_ATOMICS") == "1") {
		features.supports_native_image_atomics = false;
	}

	if (@available(macOS 13.0, iOS 16.0, tvOS 16.0, *)) {
		features.needs_arg_encoders = !([p_device supportsFamily:MTLGPUFamilyMetal3] && features.argument_buffers_tier == MTLArgumentBuffersTier2);
	}

	if (@available(macOS 13.0, iOS 16.0, tvOS 16.0, *)) {
		features.metal_fx_spatial = [MTLFXSpatialScalerDescriptor supportsDevice:p_device];
#ifdef METAL_MFXTEMPORAL_ENABLED
		features.metal_fx_temporal = [MTLFXTemporalScalerDescriptor supportsDevice:p_device];
#else
		features.metal_fx_temporal = false;
#endif
	}

	MTLCompileOptions *opts = [MTLCompileOptions new];
	features.mslVersionEnum = opts.languageVersion; // By default, Metal uses the most recent language version.
	features.mslVersionMajor = (opts.languageVersion >> 0x10) & 0xff;
	features.mslVersionMinor = (opts.languageVersion >> 0x00) & 0xff;
}

void MetalDeviceProperties::init_limits(id<MTLDevice> p_device) {
	using std::max;
	using std::min;

	// FST: https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf

	// FST: Maximum number of layers per 1D texture array, 2D texture array, or 3D texture.
	limits.maxImageArrayLayers = 2048;
	if ([p_device supportsFamily:MTLGPUFamilyApple3]) {
		// FST: Maximum 2D texture width and height.
		limits.maxFramebufferWidth = 16384;
		limits.maxFramebufferHeight = 16384;
		limits.maxViewportDimensionX = 16384;
		limits.maxViewportDimensionY = 16384;
		// FST: Maximum 1D texture width.
		limits.maxImageDimension1D = 16384;
		// FST: Maximum 2D texture width and height.
		limits.maxImageDimension2D = 16384;
		// FST: Maximum cube map texture width and height.
		limits.maxImageDimensionCube = 16384;
	} else {
		// FST: Maximum 2D texture width and height.
		limits.maxFramebufferWidth = 8192;
		limits.maxFramebufferHeight = 8192;
		limits.maxViewportDimensionX = 8192;
		limits.maxViewportDimensionY = 8192;
		// FST: Maximum 1D texture width.
		limits.maxImageDimension1D = 8192;
		// FST: Maximum 2D texture width and height.
		limits.maxImageDimension2D = 8192;
		// FST: Maximum cube map texture width and height.
		limits.maxImageDimensionCube = 8192;
	}
	// FST: Maximum 3D texture width, height, and depth.
	limits.maxImageDimension3D = 2048;

	limits.maxThreadsPerThreadGroup = p_device.maxThreadsPerThreadgroup;
	// No effective limits.
	limits.maxComputeWorkGroupCount = { std::numeric_limits<uint32_t>::max(), std::numeric_limits<uint32_t>::max(), std::numeric_limits<uint32_t>::max() };
	// https://github.com/KhronosGroup/MoltenVK/blob/568cc3acc0e2299931fdaecaaa1fc3ec5b4af281/MoltenVK/MoltenVK/GPUObjects/MVKDevice.h#L85
	limits.maxBoundDescriptorSets = SPIRV_CROSS_NAMESPACE::kMaxArgumentBuffers;
	// FST: Maximum number of color render targets per render pass descriptor.
	limits.maxColorAttachments = 8;

	// Maximum number of textures the device can access, per stage, from an argument buffer.
	if ([p_device supportsFamily:MTLGPUFamilyApple6]) {
		limits.maxTexturesPerArgumentBuffer = 1'000'000;
	} else if ([p_device supportsFamily:MTLGPUFamilyApple4]) {
		limits.maxTexturesPerArgumentBuffer = 96;
	} else {
		limits.maxTexturesPerArgumentBuffer = 31;
	}

	// Maximum number of samplers the device can access, per stage, from an argument buffer.
	if ([p_device supportsFamily:MTLGPUFamilyApple6]) {
		limits.maxSamplersPerArgumentBuffer = 1024;
	} else {
		limits.maxSamplersPerArgumentBuffer = 16;
	}

	// Maximum number of buffers the device can access, per stage, from an argument buffer.
	if ([p_device supportsFamily:MTLGPUFamilyApple6]) {
		limits.maxBuffersPerArgumentBuffer = std::numeric_limits<uint64_t>::max();
	} else if ([p_device supportsFamily:MTLGPUFamilyApple4]) {
		limits.maxBuffersPerArgumentBuffer = 96;
	} else {
		limits.maxBuffersPerArgumentBuffer = 31;
	}

	limits.minSubgroupSize = limits.maxSubgroupSize = 1;
	// These values were taken from MoltenVK.
	if (features.simdPermute) {
		limits.minSubgroupSize = 4;
		limits.maxSubgroupSize = 32;
	} else if (features.quadPermute) {
		limits.minSubgroupSize = limits.maxSubgroupSize = 4;
	}

	limits.subgroupSupportedShaderStages.set_flag(RDD::ShaderStage::SHADER_STAGE_COMPUTE_BIT);
	if (features.tessellationShader) {
		limits.subgroupSupportedShaderStages.set_flag(RDD::ShaderStage::SHADER_STAGE_TESSELATION_CONTROL_BIT);
	}
	limits.subgroupSupportedShaderStages.set_flag(RDD::ShaderStage::SHADER_STAGE_FRAGMENT_BIT);

	limits.subgroupSupportedOperations.set_flag(RD::SubgroupOperations::SUBGROUP_BASIC_BIT);
	if (features.simdPermute || features.quadPermute) {
		limits.subgroupSupportedOperations.set_flag(RD::SubgroupOperations::SUBGROUP_VOTE_BIT);
		limits.subgroupSupportedOperations.set_flag(RD::SubgroupOperations::SUBGROUP_BALLOT_BIT);
		limits.subgroupSupportedOperations.set_flag(RD::SubgroupOperations::SUBGROUP_SHUFFLE_BIT);
		limits.subgroupSupportedOperations.set_flag(RD::SubgroupOperations::SUBGROUP_SHUFFLE_RELATIVE_BIT);
	}

	if (features.simdReduction) {
		limits.subgroupSupportedOperations.set_flag(RD::SubgroupOperations::SUBGROUP_ARITHMETIC_BIT);
	}

	if (features.quadPermute) {
		limits.subgroupSupportedOperations.set_flag(RD::SubgroupOperations::SUBGROUP_QUAD_BIT);
	}

	limits.maxBufferLength = p_device.maxBufferLength;

	// FST: Maximum size of vertex descriptor layout stride.
	limits.maxVertexDescriptorLayoutStride = std::numeric_limits<uint64_t>::max();

	// Maximum number of viewports.
	if ([p_device supportsFamily:MTLGPUFamilyApple5]) {
		limits.maxViewports = 16;
	} else {
		limits.maxViewports = 1;
	}

	limits.maxPerStageBufferCount = 31;
	limits.maxPerStageSamplerCount = 16;
	if ([p_device supportsFamily:MTLGPUFamilyApple6]) {
		limits.maxPerStageTextureCount = 128;
	} else if ([p_device supportsFamily:MTLGPUFamilyApple4]) {
		limits.maxPerStageTextureCount = 96;
	} else {
		limits.maxPerStageTextureCount = 31;
	}

	limits.maxVertexInputAttributes = 31;
	limits.maxVertexInputBindings = 31;
	limits.maxVertexInputBindingStride = (2 * KIBI);
	limits.maxShaderVaryings = 31; // Accurate on Apple4 and above. See: https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf

	if ([p_device supportsFamily:MTLGPUFamilyApple4]) {
		limits.maxThreadGroupMemoryAllocation = 32768;
	} else if ([p_device supportsFamily:MTLGPUFamilyApple3]) {
		limits.maxThreadGroupMemoryAllocation = 16384;
	} else {
		limits.maxThreadGroupMemoryAllocation = 16352;
	}

#if TARGET_OS_IOS && !TARGET_OS_MACCATALYST
	limits.minUniformBufferOffsetAlignment = 64;
#endif

#if TARGET_OS_OSX
	// This is Apple Silicon specific.
	limits.minUniformBufferOffsetAlignment = 16;
#endif

	limits.maxDrawIndexedIndexValue = std::numeric_limits<uint32_t>::max() - 1;

#ifdef METAL_MFXTEMPORAL_ENABLED
	if (@available(macOS 14.0, iOS 17.0, tvOS 17.0, *)) {
		limits.temporalScalerInputContentMinScale = (double)[MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:p_device];
		limits.temporalScalerInputContentMaxScale = (double)[MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:p_device];
	} else {
		// Defaults taken from macOS 14+
		limits.temporalScalerInputContentMinScale = 1.0;
		limits.temporalScalerInputContentMaxScale = 3.0;
	}
#else
	// Defaults taken from macOS 14+
	limits.temporalScalerInputContentMinScale = 1.0;
	limits.temporalScalerInputContentMaxScale = 3.0;
#endif
}

MetalDeviceProperties::MetalDeviceProperties(id<MTLDevice> p_device) {
	init_features(p_device);
	init_limits(p_device);
}

MetalDeviceProperties::~MetalDeviceProperties() {
}

SampleCount MetalDeviceProperties::find_nearest_supported_sample_count(RenderingDevice::TextureSamples p_samples) const {
	SampleCount supported = features.supportedSampleCounts;
	if (supported & sample_count[p_samples]) {
		return sample_count[p_samples];
	}

	SampleCount requested_sample_count = sample_count[p_samples];
	// Find the nearest supported sample count.
	while (requested_sample_count > SampleCount1) {
		if (supported & requested_sample_count) {
			return requested_sample_count;
		}
		requested_sample_count = (SampleCount)(requested_sample_count >> 1);
	}

	return SampleCount1;
}

// region static members

const SampleCount MetalDeviceProperties::sample_count[RenderingDevice::TextureSamples::TEXTURE_SAMPLES_MAX] = {
	SampleCount1,
	SampleCount2,
	SampleCount4,
	SampleCount8,
	SampleCount16,
	SampleCount32,
	SampleCount64,
};

// endregion
