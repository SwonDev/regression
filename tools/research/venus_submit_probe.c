// SPDX-License-Identifier: MIT
// A display-free Vulkan probe for the isolated Linux ARM research lab.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

static void fail(const char *operation, VkResult result) {
    fprintf(stderr, "%s failed with VkResult %d\n", operation, result);
    exit(EXIT_FAILURE);
}

#define VK_CHECK(operation)                                                   \
    do {                                                                      \
        VkResult result_ = (operation);                                       \
        if (result_ != VK_SUCCESS) {                                          \
            fail(#operation, result_);                                        \
        }                                                                     \
    } while (0)

int main(void) {
    const VkApplicationInfo application_info = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "Regression Venus submit probe",
        .applicationVersion = VK_MAKE_API_VERSION(0, 1, 0, 0),
        .pEngineName = "none",
        .engineVersion = VK_MAKE_API_VERSION(0, 1, 0, 0),
        .apiVersion = VK_API_VERSION_1_1,
    };
    const VkInstanceCreateInfo instance_info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &application_info,
    };

    VkInstance instance = VK_NULL_HANDLE;
    VK_CHECK(vkCreateInstance(&instance_info, NULL, &instance));

    uint32_t physical_device_count = 0;
    VK_CHECK(vkEnumeratePhysicalDevices(instance, &physical_device_count, NULL));
    if (physical_device_count == 0) {
        fprintf(stderr, "No Vulkan physical devices were exposed.\n");
        return EXIT_FAILURE;
    }

    VkPhysicalDevice *physical_devices = calloc(physical_device_count, sizeof(*physical_devices));
    if (physical_devices == NULL) {
        perror("calloc");
        return EXIT_FAILURE;
    }
    VK_CHECK(vkEnumeratePhysicalDevices(instance, &physical_device_count, physical_devices));
    VkPhysicalDevice physical_device = physical_devices[0];
    free(physical_devices);

    VkPhysicalDeviceDriverProperties driver_properties = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES,
    };
    VkPhysicalDeviceProperties2 properties = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
        .pNext = &driver_properties,
    };
    vkGetPhysicalDeviceProperties2(physical_device, &properties);

    uint32_t queue_family_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, NULL);
    VkQueueFamilyProperties *queue_families = calloc(queue_family_count, sizeof(*queue_families));
    if (queue_families == NULL) {
        perror("calloc");
        return EXIT_FAILURE;
    }
    vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, queue_families);

    uint32_t queue_family_index = UINT32_MAX;
    for (uint32_t index = 0; index < queue_family_count; ++index) {
        const VkQueueFlags flags = queue_families[index].queueFlags;
        if (queue_families[index].queueCount > 0 &&
            (flags & (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT)) != 0) {
            queue_family_index = index;
            break;
        }
    }
    free(queue_families);
    if (queue_family_index == UINT32_MAX) {
        fprintf(stderr, "No graphics or compute queue family was exposed.\n");
        return EXIT_FAILURE;
    }

    const float priority = 1.0f;
    const VkDeviceQueueCreateInfo queue_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = queue_family_index,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    const VkDeviceCreateInfo device_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_info,
    };

    VkDevice device = VK_NULL_HANDLE;
    VK_CHECK(vkCreateDevice(physical_device, &device_info, NULL, &device));
    VkQueue queue = VK_NULL_HANDLE;
    vkGetDeviceQueue(device, queue_family_index, 0, &queue);

    const VkCommandPoolCreateInfo pool_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
        .queueFamilyIndex = queue_family_index,
    };
    VkCommandPool command_pool = VK_NULL_HANDLE;
    VK_CHECK(vkCreateCommandPool(device, &pool_info, NULL, &command_pool));

    const VkCommandBufferAllocateInfo allocation_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = command_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    VkCommandBuffer command_buffer = VK_NULL_HANDLE;
    VK_CHECK(vkAllocateCommandBuffers(device, &allocation_info, &command_buffer));

    const VkCommandBufferBeginInfo begin_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    VK_CHECK(vkBeginCommandBuffer(command_buffer, &begin_info));
    VK_CHECK(vkEndCommandBuffer(command_buffer));

    const VkSubmitInfo submit_info = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &command_buffer,
    };
    const VkFenceCreateInfo fence_info = {
        .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
    };
    VkFence fence = VK_NULL_HANDLE;
    VK_CHECK(vkCreateFence(device, &fence_info, NULL, &fence));
    VK_CHECK(vkQueueSubmit(queue, 1, &submit_info, fence));
    VK_CHECK(vkWaitForFences(device, 1, &fence, VK_TRUE, 10ULL * 1000ULL * 1000ULL * 1000ULL));

    printf("VENUS_SUBMIT_OK\n");
    printf("device=%s\n", properties.properties.deviceName);
    printf("driver=%s\n", driver_properties.driverName);
    printf("driver_info=%s\n", driver_properties.driverInfo);
    printf("api=%u.%u.%u\n",
           VK_API_VERSION_MAJOR(properties.properties.apiVersion),
           VK_API_VERSION_MINOR(properties.properties.apiVersion),
           VK_API_VERSION_PATCH(properties.properties.apiVersion));
    printf("queue_family=%u\n", queue_family_index);

    vkDestroyFence(device, fence, NULL);
    vkDestroyCommandPool(device, command_pool, NULL);
    vkDestroyDevice(device, NULL);
    vkDestroyInstance(instance, NULL);
    return EXIT_SUCCESS;
}
