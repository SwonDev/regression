#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <vulkan/vulkan.h>

static bool has_device_extension(VkPhysicalDevice device, const char *name) {
  uint32_t count = 0;
  if (vkEnumerateDeviceExtensionProperties(device, NULL, &count, NULL) != VK_SUCCESS) {
    return false;
  }

  VkExtensionProperties properties[count];
  if (vkEnumerateDeviceExtensionProperties(device, NULL, &count, properties) != VK_SUCCESS) {
    return false;
  }

  for (uint32_t index = 0; index < count; ++index) {
    if (strcmp(properties[index].extensionName, name) == 0) {
      return true;
    }
  }

  return false;
}

int main(void) {
  uint32_t instance_version = VK_API_VERSION_1_0;
  if (vkEnumerateInstanceVersion(&instance_version) != VK_SUCCESS) {
    fprintf(stderr, "probe: vkEnumerateInstanceVersion failed\n");
    return 10;
  }

  const VkApplicationInfo application = {
      .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .pApplicationName = "Regression FEX Vulkan thunk probe",
      .applicationVersion = 1,
      .pEngineName = "Regression research",
      .engineVersion = 1,
      .apiVersion = instance_version,
  };
  const VkInstanceCreateInfo create_info = {
      .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
      .pApplicationInfo = &application,
  };

  VkInstance instance = VK_NULL_HANDLE;
  const VkResult create_result = vkCreateInstance(&create_info, NULL, &instance);
  if (create_result != VK_SUCCESS) {
    fprintf(stderr, "probe: vkCreateInstance failed: %d\n", create_result);
    return 11;
  }

  uint32_t device_count = 0;
  if (vkEnumeratePhysicalDevices(instance, &device_count, NULL) != VK_SUCCESS || device_count == 0) {
    fprintf(stderr, "probe: no physical devices\n");
    vkDestroyInstance(instance, NULL);
    return 12;
  }

  VkPhysicalDevice devices[device_count];
  if (vkEnumeratePhysicalDevices(instance, &device_count, devices) != VK_SUCCESS) {
    fprintf(stderr, "probe: device enumeration failed\n");
    vkDestroyInstance(instance, NULL);
    return 13;
  }

  bool venus_found = false;
  bool depth_clip_extension = false;
  bool depth_clip_feature = false;

  for (uint32_t index = 0; index < device_count; ++index) {
    VkPhysicalDeviceProperties properties = {0};
    vkGetPhysicalDeviceProperties(devices[index], &properties);

    VkPhysicalDeviceDepthClipEnableFeaturesEXT depth_clip = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DEPTH_CLIP_ENABLE_FEATURES_EXT,
    };
    VkPhysicalDeviceFeatures2 features = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
        .pNext = &depth_clip,
    };
    vkGetPhysicalDeviceFeatures2(devices[index], &features);

    const bool has_extension =
        has_device_extension(devices[index], VK_EXT_DEPTH_CLIP_ENABLE_EXTENSION_NAME);
    const bool is_venus = strstr(properties.deviceName, "Virtio-GPU Venus") != NULL;

    printf("probe: device=%s vendor=0x%04x device_id=0x%04x extension=%s feature=%s\n",
           properties.deviceName,
           properties.vendorID,
           properties.deviceID,
           has_extension ? "yes" : "no",
           depth_clip.depthClipEnable ? "yes" : "no");
    fflush(stdout);

    if (is_venus) {
      venus_found = true;
      depth_clip_extension = has_extension;
      depth_clip_feature = depth_clip.depthClipEnable == VK_TRUE;
    }
  }

  vkDestroyInstance(instance, NULL);

  if (!venus_found) {
    fprintf(stderr, "probe: Venus was not enumerated\n");
    return 20;
  }
  if (!depth_clip_extension || !depth_clip_feature) {
    fprintf(stderr, "probe: required depth-clip capability is incomplete\n");
    return 21;
  }

  puts("probe: PASS");
  return 0;
}
