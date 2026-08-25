// Reproduce fuera de todo juego el quinto bloqueo de Enshrouded: un shader de cómputo declara y
// lee recursos de un descriptor set que la aplicación no enlaza antes del dispatch.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

#define CHK(x) do { VkResult r_=(x); if(r_!=VK_SUCCESS){ printf("FALLO %s -> %d\n", #x, r_); return 2; } } while(0)

static uint32_t tipoMemoria(VkPhysicalDevice pd, uint32_t bits, VkMemoryPropertyFlags props) {
    VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    for (uint32_t i=0;i<mp.memoryTypeCount;i++)
        if ((bits & (1u<<i)) && (mp.memoryTypes[i].propertyFlags & props)==props) return i;
    return UINT32_MAX;
}

int main(int argc, char** argv) {
    int enlazarSet4 = 0, rangoParcial = 0;
    const char* spv = "probe.spv";
    for (int i=1;i<argc;i++) {
        if (!strcmp(argv[i],"--enlazar-set4")) enlazarSet4 = 1;
        else if (!strcmp(argv[i],"--rango-parcial")) rangoParcial = 1;
        else if (argv[i][0] != '-') spv = argv[i];
    }
    printf("caso: set alto %s, rango del descriptor %s\n",
           enlazarSet4 ? "ENLAZADO" : "SIN ENLAZAR",
           rangoParcial ? "PARCIAL (1/4 del buffer)" : "VK_WHOLE_SIZE");

    const char* extInst[] = { "VK_KHR_get_physical_device_properties2" };
    VkApplicationInfo ai = { .sType=VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion=VK_API_VERSION_1_2 };
    VkInstanceCreateInfo ici = { .sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo=&ai,
        .enabledExtensionCount=1, .ppEnabledExtensionNames=extInst };
    VkInstance inst; CHK(vkCreateInstance(&ici,NULL,&inst));

    uint32_t n=0; CHK(vkEnumeratePhysicalDevices(inst,&n,NULL));
    VkPhysicalDevice pds[8]; if(n>8)n=8; CHK(vkEnumeratePhysicalDevices(inst,&n,pds));
    VkPhysicalDevice pd = pds[0];
    VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(pd,&props);
    printf("dispositivo: %s  maxBoundDescriptorSets=%u\n", props.deviceName, props.limits.maxBoundDescriptorSets);

    uint32_t qn=0; vkGetPhysicalDeviceQueueFamilyProperties(pd,&qn,NULL);
    VkQueueFamilyProperties qs[16]; if(qn>16)qn=16; vkGetPhysicalDeviceQueueFamilyProperties(pd,&qn,qs);
    uint32_t qf=0; for(uint32_t i=0;i<qn;i++) if(qs[i].queueFlags & VK_QUEUE_COMPUTE_BIT){ qf=i; break; }

    float pri=1.0f;
    VkDeviceQueueCreateInfo qci={ .sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=qf,.queueCount=1,.pQueuePriorities=&pri };
    VkDeviceCreateInfo dci={ .sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&qci };
    VkDevice dev; CHK(vkCreateDevice(pd,&dci,NULL,&dev));
    VkQueue q; vkGetDeviceQueue(dev,qf,0,&q);

    // Dos layouts con una binding cada uno, y tres vacíos para los sets 1..3.
    VkDescriptorSetLayoutBinding b={ .binding=0,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.descriptorCount=1,.stageFlags=VK_SHADER_STAGE_COMPUTE_BIT };
    VkDescriptorSetLayoutCreateInfo li={ .sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,.bindingCount=1,.pBindings=&b };
    VkDescriptorSetLayoutCreateInfo lv={ .sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,.bindingCount=0 };
    VkDescriptorSetLayout dsl0,dsl4,dslv; CHK(vkCreateDescriptorSetLayout(dev,&li,NULL,&dsl0));
    CHK(vkCreateDescriptorSetLayout(dev,&li,NULL,&dsl4));
    CHK(vkCreateDescriptorSetLayout(dev,&lv,NULL,&dslv));
    VkDescriptorSetLayout sets[5]={dsl0,dslv,dslv,dslv,dsl4};
    if (strstr(argc>1?argv[argc-1]:"", "length") != NULL) sets[1]=dsl4;
    VkPushConstantRange pcr={ .stageFlags=VK_SHADER_STAGE_COMPUTE_BIT,.offset=0,.size=4 };
    VkPipelineLayoutCreateInfo pli={ .sType=VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,.setLayoutCount=5,.pSetLayouts=sets,
        .pushConstantRangeCount=1,.pPushConstantRanges=&pcr };
    VkPipelineLayout pl; CHK(vkCreatePipelineLayout(dev,&pli,NULL,&pl));

    FILE* f=fopen(spv,"rb");
    if(!f){ printf("no se pudo abrir el SPIR-V\n"); return 2; }
    fseek(f,0,SEEK_END); long sz=ftell(f); fseek(f,0,SEEK_SET);
    uint32_t* code=malloc(sz); fread(code,1,sz,f); fclose(f);
    VkShaderModuleCreateInfo smi={ .sType=VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,.codeSize=(size_t)sz,.pCode=code };
    VkShaderModule sm; CHK(vkCreateShaderModule(dev,&smi,NULL,&sm));
    VkComputePipelineCreateInfo cpi={ .sType=VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,.layout=pl,
        .stage={ .sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,.stage=VK_SHADER_STAGE_COMPUTE_BIT,.module=sm,.pName="main" } };
    VkPipeline pipe, pipe2;
    CHK(vkCreateComputePipelines(dev,VK_NULL_HANDLE,1,&cpi,NULL,&pipe));
    CHK(vkCreateComputePipelines(dev,VK_NULL_HANDLE,1,&cpi,NULL,&pipe2));
    printf("pipeline de cómputo creada\n");

    // Buffers
    VkBuffer buf[2]; VkDeviceMemory mem[2];
    for(int i=0;i<2;i++){
        VkBufferCreateInfo bci={ .sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,.size=4096,.usage=VK_BUFFER_USAGE_STORAGE_BUFFER_BIT };
        CHK(vkCreateBuffer(dev,&bci,NULL,&buf[i]));
        VkMemoryRequirements mr; vkGetBufferMemoryRequirements(dev,buf[i],&mr);
        VkMemoryAllocateInfo mai={ .sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=mr.size,
            .memoryTypeIndex=tipoMemoria(pd,mr.memoryTypeBits,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
        CHK(vkAllocateMemory(dev,&mai,NULL,&mem[i]));
        CHK(vkBindBufferMemory(dev,buf[i],mem[i],0));
    }

    VkDescriptorPoolSize ps={ .type=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.descriptorCount=4 };
    VkDescriptorPoolCreateInfo dpi={ .sType=VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,.maxSets=4,.poolSizeCount=1,.pPoolSizes=&ps };
    VkDescriptorPool dp; CHK(vkCreateDescriptorPool(dev,&dpi,NULL,&dp));
    VkDescriptorSetLayout alloc[2]={dsl0,dsl4}; VkDescriptorSet ds[2];
    VkDescriptorSetAllocateInfo dsi={ .sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,.descriptorPool=dp,.descriptorSetCount=2,.pSetLayouts=alloc };
    CHK(vkAllocateDescriptorSets(dev,&dsi,ds));
    for(int i=0;i<2;i++){
        VkDescriptorBufferInfo dbi={ .buffer=buf[i],.offset=0,
            .range=(i==1 && rangoParcial) ? 1024 : VK_WHOLE_SIZE };
        VkWriteDescriptorSet w={ .sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,.dstSet=ds[i],.dstBinding=0,
            .descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.pBufferInfo=&dbi };
        vkUpdateDescriptorSets(dev,1,&w,0,NULL);
    }

    VkCommandPoolCreateInfo cpci={ .sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,.queueFamilyIndex=qf };
    VkCommandPool cp; CHK(vkCreateCommandPool(dev,&cpci,NULL,&cp));
    VkCommandBufferAllocateInfo cbi={ .sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,.commandPool=cp,.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY,.commandBufferCount=1 };
    VkCommandBuffer cb; CHK(vkAllocateCommandBuffers(dev,&cbi,&cb));
    VkCommandBufferBeginInfo bi={ .sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    CHK(vkBeginCommandBuffer(cb,&bi));
    vkCmdBindPipeline(cb,VK_PIPELINE_BIND_POINT_COMPUTE,pipe);
    vkCmdBindDescriptorSets(cb,VK_PIPELINE_BIND_POINT_COMPUTE,pl,0,1,&ds[0],0,NULL);
    {
        uint32_t destino = (strstr(spv,"length") != NULL) ? 1u : 4u;
        if (enlazarSet4 || destino==1u)
            vkCmdBindDescriptorSets(cb,VK_PIPELINE_BIND_POINT_COMPUTE,pl,destino,1,&ds[1],0,NULL);
    }
    uint32_t ranura=0; vkCmdPushConstants(cb,pl,VK_SHADER_STAGE_COMPUTE_BIT,0,4,&ranura);
    vkCmdDispatch(cb,64,1,1);
    // Se cambia de pipeline y se vuelve, SIN re-enlazar los descriptor sets: así los buffers dejan
    // de estar sucios mientras el buffer implícito de tamaños vuelve a marcarse para enlazar.
    vkCmdBindPipeline(cb,VK_PIPELINE_BIND_POINT_COMPUTE,pipe2);
    ranura=1; vkCmdPushConstants(cb,pl,VK_SHADER_STAGE_COMPUTE_BIT,0,4,&ranura);
    vkCmdDispatch(cb,64,1,1);
    vkCmdBindPipeline(cb,VK_PIPELINE_BIND_POINT_COMPUTE,pipe);
    ranura=2; vkCmdPushConstants(cb,pl,VK_SHADER_STAGE_COMPUTE_BIT,0,4,&ranura);
    vkCmdDispatch(cb,64,1,1);
    CHK(vkEndCommandBuffer(cb));

    VkSubmitInfo si={ .sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.commandBufferCount=1,.pCommandBuffers=&cb };
    VkFenceCreateInfo fci={ .sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence; CHK(vkCreateFence(dev,&fci,NULL,&fence));
    CHK(vkQueueSubmit(q,1,&si,fence));
    VkResult wr = vkWaitForFences(dev,1,&fence,VK_TRUE,5000000000ULL);
    printf("RESULTADO: vkWaitForFences -> %d %s\n", wr,
           wr==VK_ERROR_DEVICE_LOST ? "(VK_ERROR_DEVICE_LOST — REPRODUCIDO)" : wr==VK_SUCCESS ? "(sin fallo)" : "");
    if (wr==VK_SUCCESS) {
        void* p=NULL;
        if (vkMapMemory(dev,mem[0],0,VK_WHOLE_SIZE,0,&p)==VK_SUCCESS) {
            uint32_t* v=(uint32_t*)p;
            printf("  length() por dispatch: [1]=%u  [2 tras cambiar de pipeline]=%u  [3 al volver]=%u\n",
                   v[0], v[1], v[2]);
            vkUnmapMemory(dev,mem[0]);
        }
    }
    return wr==VK_SUCCESS ? 0 : 1;
}
