/**
 * 剑影江湖 (com.jyjh.whwb) v1.8.1 - 无CD无能量技能插件
 * 
 * 不依赖 Cydia Substrate / MSHookFunction!
 * 使用直接内存补丁方式，在IL2CPP函数入口写入return true
 * 
 * 原理:
 *   CheckSkillAttackCanUse (0x2A9218) 和 CheckSkillIsReady (0x2A9B08)
 *   都是返回 Boolean 的函数，patch为:
 *     mov w0, #1    // return true
 *     ret
 *   只需4个字节: 0x20 0x00 0x80 0x52 (mov w0, #1) + 0xC0 0x03 0x5F 0xD6 (ret)
 *
 * 适配: iOS 15.0+ arm64, 无根越狱
 */

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

#define LOG(fmt, args...) NSLog(@"[JYJH_NoCDNoEnergy] " fmt, ##args)

/* IL2CPP 函数偏移 (v1.8.1 dump RVA) */
static const uint64_t OFF_CheckSkillAttackCanUse = 0x2A9218;
static const uint64_t OFF_CheckSkillIsReady       = 0x2A9B08;

/* arm64 指令编码 */
/* mov w0, #1 = 0x52800020 */
/* ret        = 0xD65F03C0 */
static const uint32_t ARM64_MOV_W0_1 = 0x52800020;
static const uint32_t ARM64_RET      = 0xD65F03C0;

/* 修改内存保护并写入补丁 */
static kern_return_t patchMemory(void *addr, const void *data, size_t size) {
    vm_address_t page = (vm_address_t)addr & ~(vm_page_size - 1);
    vm_size_t pageSize = vm_page_size;
    
    /* 先修改内存保护为可读写 */
    kern_return_t kr = vm_protect(mach_task_self(), page, pageSize, 
                                   false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        LOG(@"vm_protect RWX failed: %d", kr);
        /* 尝试 copy-on-write 方式 */
        kr = vm_protect(mach_task_self(), page, pageSize, 
                        false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
        if (kr != KERN_SUCCESS) {
            LOG(@"vm_protect COPY failed: %d", kr);
            return kr;
        }
    }
    
    /* 写入补丁 */
    memcpy(addr, data, size);
    
    /* 刷新指令缓存 */
    sys_icache_invalidate(addr, size);
    
    /* 恢复保护为只读+执行 */
    kr = vm_protect(mach_task_self(), page, pageSize, false, VM_PROT_READ | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        LOG(@"vm_protect RX restore failed (non-fatal): %d", kr);
    }
    
    return KERN_SUCCESS;
}

/* 查找模块基址 */
static uint64_t findModuleBase(const char *partialName) {
    uint32_t cnt = _dyld_image_count();
    for (uint32_t i = 0; i < cnt; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, partialName)) {
            return (uint64_t)_dyld_get_image_header(i);
        }
    }
    return 0;
}

/* 应用补丁 */
static void applyPatches(void) {
    static BOOL applied = NO;
    if (applied) return;
    
    uint64_t base = findModuleBase("FrameSync.code.dll");
    if (!base) {
        LOG(@"FrameSync.code.dll not loaded, retry in 2s...");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ applyPatches(); });
        return;
    }
    
    LOG(@"FrameSync.code.dll base = 0x%llx", base);
    
    /* 补丁数据: mov w0, #1; ret (8字节) */
    uint32_t patch[] = { ARM64_MOV_W0_1, ARM64_RET };
    
    /* Patch CheckSkillAttackCanUse -> return true */
    void *addr1 = (void *)(base + OFF_CheckSkillAttackCanUse);
    kern_return_t kr1 = patchMemory(addr1, patch, sizeof(patch));
    LOG(@"Patch CheckSkillAttackCanUse @ %p: %s", addr1, kr1 == KERN_SUCCESS ? "OK" : "FAILED");
    
    /* Patch CheckSkillIsReady -> return true */
    void *addr2 = (void *)(base + OFF_CheckSkillIsReady);
    kern_return_t kr2 = patchMemory(addr2, patch, sizeof(patch));
    LOG(@"Patch CheckSkillIsReady       @ %p: %s", addr2, kr2 == KERN_SUCCESS ? "OK" : "FAILED");
    
    if (kr1 == KERN_SUCCESS && kr2 == KERN_SUCCESS) {
        applied = YES;
        LOG(@"All patches applied! NoCD + NoEnergy active.");
    } else {
        LOG(@"Some patches failed, will retry...");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ applyPatches(); });
    }
}

__attribute__((constructor))
static void initialize(void) {
    LOG(@"JYJH_NoCDNoEnergy v2.0 loaded (memory patch, no substrate)");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ applyPatches(); });
}