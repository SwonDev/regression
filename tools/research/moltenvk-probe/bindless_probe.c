// Ejercita el patrón bindless de descriptor indexing contra el MoltenVK compilado, sin juego.
// Reserva el descriptor set con una cuenta variable y hace que el shader indexe más allá, que es
// la forma en que un argument buffer acaba siendo más pequeño de lo que el shader lee.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CHK(x) do { VkResult r_=(x); if(r_!=VK_SUCCESS){ printf("FALLO %s -> %d\n", #x, r_); return 2; } } while(0)
#define RECURSOS_DECLARADOS 1024

static uint32_t tipoMemoria(VkPhysicalDevice pd, uint32_t bits, VkMemoryPropertyFlags props) {
    VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd,&mp);
    for (uint32_t i=0;i<mp.memoryTypeCount;i++)
        if ((bits & (1u<<i)) && (mp.memoryTypes[i].propertyFlags & props)==props) return i;
    return UINT32_MAX;
}

int main(int argc, char** argv) {
    uint32_t reservados = 4, indice = 4;
    const char* spv = "probe-bindless.spv";
    for (int i=1;i<argc;i++) {
        if (!strncmp(argv[i],"--reservados=",13)) reservados = (uint32_t)atoi(argv[i]+13);
        else if (!strncmp(argv[i],"--indice=",9)) indice = (uint32_t)atoi(argv[i]+9);
        else if (argv[i][0] != '-') spv = argv[i];
    }
    printf("caso bindless: %u descriptores reservados, el shader indexa el %u\n", reservados, indice);

    const char* extInst[] = { "VK_KHR_get_physical_device_properties2" };
    VkApplicationInfo ai={ .sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.apiVersion=VK_API_VERSION_1_2 };
    VkInstanceCreateInfo ici={ .sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&ai,
        .enabledExtensionCount=1,.ppEnabledExtensionNames=extInst };
    VkInstance inst; CHK(vkCreateInstance(&ici,NULL,&inst));
    uint32_t n=0; CHK(vkEnumeratePhysicalDevices(inst,&n,NULL));
    VkPhysicalDevice pds[8]; if(n>8)n=8; CHK(vkEnumeratePhysicalDevices(inst,&n,pds));
    VkPhysicalDevice pd=pds[0];

    VkPhysicalDeviceVulkan12Features f12={ .sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES };
    VkPhysicalDeviceFeatures2 f2={ .sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,.pNext=&f12 };
    vkGetPhysicalDeviceFeatures2(pd,&f2);
    printf("  runtimeDescriptorArray=%u variableDescriptorCount=%u partiallyBound=%u nonUniformSSBO=%u\n",
           f12.runtimeDescriptorArray, f12.descriptorBindingVariableDescriptorCount,
           f12.descriptorBindingPartiallyBound, f12.shaderStorageBufferArrayNonUniformIndexing);
    if (!f12.runtimeDescriptorArray || !f12.descriptorBindingVariableDescriptorCount) {
        printf("RESULTADO: el dispositivo no ofrece descriptor indexing; no aplica\n"); return 3;
    }

    uint32_t qn=0; vkGetPhysicalDeviceQueueFamilyProperties(pd,&qn,NULL);
    VkQueueFamilyProperties qs[16]; if(qn>16)qn=16; vkGetPhysicalDeviceQueueFamilyProperties(pd,&qn,qs);
    uint32_t qf=0; for(uint32_t i=0;i<qn;i++) if(qs[i].queueFlags & VK_QUEUE_COMPUTE_BIT){ qf=i; break; }
    float pri=1.0f;
    VkDeviceQueueCreateInfo qci={ .sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=qf,.queueCount=1,.pQueuePriorities=&pri };
    VkPhysicalDeviceVulkan12Features e12={ .sType=VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
        .runtimeDescriptorArray=VK_TRUE,.descriptorBindingVariableDescriptorCount=VK_TRUE,
        .descriptorBindingPartiallyBound=VK_TRUE,.shaderStorageBufferArrayNonUniformIndexing=VK_TRUE };
    VkDeviceCreateInfo dci={ .sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.pNext=&e12,
        .queueCreateInfoCount=1,.pQueueCreateInfos=&qci };
    VkDevice dev; CHK(vkCreateDevice(pd,&dci,NULL,&dev));
    VkQueue q; vkGetDeviceQueue(dev,qf,0,&q);

    VkDescriptorSetLayoutBinding b0={ .binding=0,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.descriptorCount=1,.stageFlags=VK_SHADER_STAGE_COMPUTE_BIT };
    VkDescriptorSetLayoutCreateInfo l0={ .sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,.bindingCount=1,.pBindings=&b0 };
    VkDescriptorSetLayout dsl0; CHK(vkCreateDescriptorSetLayout(dev,&l0,NULL,&dsl0));

    VkDescriptorSetLayoutBinding b1={ .binding=0,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount=RECURSOS_DECLARADOS,.stageFlags=VK_SHADER_STAGE_COMPUTE_BIT };
    VkDescriptorBindingFlags bf = VK_DESCRIPTOR_BINDING_VARIABLE_DESCRIPTOR_COUNT_BIT
                                | VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT;
    VkDescriptorSetLayoutBindingFlagsCreateInfo bfi={ .sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO,
        .bindingCount=1,.pBindingFlags=&bf };
    VkDescriptorSetLayoutCreateInfo l1={ .sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,.pNext=&bfi,.bindingCount=1,.pBindings=&b1 };
    VkDescriptorSetLayout dsl1; CHK(vkCreateDescriptorSetLayout(dev,&l1,NULL,&dsl1));

    VkPushConstantRange pcr={ .stageFlags=VK_SHADER_STAGE_COMPUTE_BIT,.offset=0,.size=4 };
    VkDescriptorSetLayout sets[2]={dsl0,dsl1};
    VkPipelineLayoutCreateInfo pli={ .sType=VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,.setLayoutCount=2,.pSetLayouts=sets,
        .pushConstantRangeCount=1,.pPushConstantRanges=&pcr };
    VkPipelineLayout pl; CHK(vkCreatePipelineLayout(dev,&pli,NULL,&pl));

    FILE* f=fopen(spv,"rb"); if(!f){ printf("no se pudo abrir %s\n",spv); return 2; }
    fseek(f,0,SEEK_END); long sz=ftell(f); fseek(f,0,SEEK_SET);
    uint32_t* code=malloc(sz); fread(code,1,sz,f); fclose(f);
    VkShaderModuleCreateInfo smi={ .sType=VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,.codeSize=(size_t)sz,.pCode=code };
    VkShaderModule sm; CHK(vkCreateShaderModule(dev,&smi,NULL,&sm));
    VkComputePipelineCreateInfo cpi={ .sType=VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,.layout=pl,
        .stage={ .sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,.stage=VK_SHADER_STAGE_COMPUTE_BIT,.module=sm,.pName="main" } };
    VkPipeline pipe; CHK(vkCreateComputePipelines(dev,VK_NULL_HANDLE,1,&cpi,NULL,&pipe));
    printf("  pipeline bindless creada\n");

    uint32_t nbuf = reservados + 1;
    VkBuffer* buf=calloc(nbuf,sizeof(VkBuffer)); VkDeviceMemory* mem=calloc(nbuf,sizeof(VkDeviceMemory));
    for(uint32_t i=0;i<nbuf;i++){
        VkBufferCreateInfo bci={ .sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,.size=256,.usage=VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
        CHK(vkCreateBuffer(dev,&bci,NULL,&buf[i]));
        VkMemoryRequirements mr; vkGetBufferMemoryRequirements(dev,buf[i],&mr);
        VkMemoryAllocateInfo mai={ .sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=mr.size,
            .memoryTypeIndex=tipoMemoria(pd,mr.memoryTypeBits,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
        CHK(vkAllocateMemory(dev,&mai,NULL,&mem[i]));
        CHK(vkBindBufferMemory(dev,buf[i],mem[i],0));
        void* p; CHK(vkMapMemory(dev,mem[i],0,VK_WHOLE_SIZE,0,&p)); memset(p,0,256); ((uint32_t*)p)[0]=0xA5A50000u+i; vkUnmapMemory(dev,mem[i]);
    }

    VkDescriptorPoolSize ps={ .type=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.descriptorCount=RECURSOS_DECLARADOS+1 };
    VkDescriptorPoolCreateInfo dpi={ .sType=VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,.maxSets=2,.poolSizeCount=1,.pPoolSizes=&ps };
    VkDescriptorPool dp; CHK(vkCreateDescriptorPool(dev,&dpi,NULL,&dp));

    VkDescriptorSet ds0, ds1;
    VkDescriptorSetAllocateInfo a0={ .sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,.descriptorPool=dp,.descriptorSetCount=1,.pSetLayouts=&dsl0 };
    CHK(vkAllocateDescriptorSets(dev,&a0,&ds0));
    VkDescriptorSetVariableDescriptorCountAllocateInfo vda={ .sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_VARIABLE_DESCRIPTOR_COUNT_ALLOCATE_INFO,
        .descriptorSetCount=1,.pDescriptorCounts=&reservados };
    VkDescriptorSetAllocateInfo a1={ .sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,.pNext=&vda,.descriptorPool=dp,.descriptorSetCount=1,.pSetLayouts=&dsl1 };
    CHK(vkAllocateDescriptorSets(dev,&a1,&ds1));

    VkDescriptorBufferInfo dbi0={ .buffer=buf[0],.offset=0,.range=VK_WHOLE_SIZE };
    VkWriteDescriptorSet w0={ .sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,.dstSet=ds0,.dstBinding=0,.descriptorCount=1,
        .descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.pBufferInfo=&dbi0 };
    vkUpdateDescriptorSets(dev,1,&w0,0,NULL);
    if (reservados > 0) {
        VkDescriptorBufferInfo* dbis=calloc(reservados,sizeof(VkDescriptorBufferInfo));
        for(uint32_t i=0;i<reservados;i++){ dbis[i].buffer=buf[i]; dbis[i].range=VK_WHOLE_SIZE; }
        VkWriteDescriptorSet w1={ .sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,.dstSet=ds1,.dstBinding=0,.dstArrayElement=0,
            .descriptorCount=reservados,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.pBufferInfo=dbis };
        vkUpdateDescriptorSets(dev,1,&w1,0,NULL);
    }

    VkCommandPoolCreateInfo cpci={ .sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,.queueFamilyIndex=qf };
    VkCommandPool cp; CHK(vkCreateCommandPool(dev,&cpci,NULL,&cp));
    VkCommandBufferAllocateInfo cbi={ .sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,.commandPool=cp,.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY,.commandBufferCount=1 };
    VkCommandBuffer cb; CHK(vkAllocateCommandBuffers(dev,&cbi,&cb));
    VkCommandBufferBeginInfo bi={ .sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    CHK(vkBeginCommandBuffer(cb,&bi));
    vkCmdBindPipeline(cb,VK_PIPELINE_BIND_POINT_COMPUTE,pipe);
    VkDescriptorSet ambos[2]={ds0,ds1};
    vkCmdBindDescriptorSets(cb,VK_PIPELINE_BIND_POINT_COMPUTE,pl,0,2,ambos,0,NULL);
    vkCmdPushConstants(cb,pl,VK_SHADER_STAGE_COMPUTE_BIT,0,4,&indice);
    vkCmdDispatch(cb,1,1,1);
    CHK(vkEndCommandBuffer(cb));

    VkSubmitInfo si={ .sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.commandBufferCount=1,.pCommandBuffers=&cb };
    VkFenceCreateInfo fci={ .sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence; CHK(vkCreateFence(dev,&fci,NULL,&fence));
    CHK(vkQueueSubmit(q,1,&si,fence));
    VkResult wr=vkWaitForFences(dev,1,&fence,VK_TRUE,5000000000ULL);
    printf("RESULTADO: vkWaitForFences -> %d %s\n", wr,
           wr==VK_ERROR_DEVICE_LOST ? "(VK_ERROR_DEVICE_LOST — REPRODUCIDO)" : wr==VK_SUCCESS ? "(sin fallo)" : "");
    if (wr==VK_SUCCESS) {
        void* p; if (vkMapMemory(dev,mem[0],0,VK_WHOLE_SIZE,0,&p)==VK_SUCCESS) {
            printf("  el shader leyó 0x%08X\n", ((uint32_t*)p)[0]); vkUnmapMemory(dev,mem[0]);
        }
    }
    return wr==VK_SUCCESS ? 0 : 1;
}
