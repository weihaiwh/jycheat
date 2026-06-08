/**
 * 剑影江湖 (com.jyjh.whwb) v1.8.1 - 无CD无能量技能插件
 * v2.0: 直接内存补丁，不依赖Substrate
 * 
 * 偏移:
 *   CheckSkillAttackCanUse: 0x2A9218 -> mov w0,#1; ret (无CD)
 *   CheckSkillIsReady:      0x2A9B08 -> mov w0,#1; ret (无能量)
 *
 * 适配: iOS 15.0+ arm64, 无根越狱
 */

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>

/* 声明缺少的函数 */
extern void NSLog(NSString *format, ...) __attribute__((format(NSString, 1, 2)));
extern void sys_icache_invalidate(void *start, size_t len);

#define LOG(fmt, args...) NSLog(@"[JYJH_NoCDNoEnergy] " fmt, ##args)

/* IL2CPP 函数偏移 */
static const uint64_t OFF_CheckSkillAttackCanUse = 0x2A9218;
static const uint64_t OFF_CheckSkillIsReady       = 0x2A9B08;

/* arm64: mov w0, #1; ret */
static const uint32_t ARM64_MOV_W0_1 = 0x52800020;
static const uint32_t ARM64_RET      = 0xD65F03C0;

/* 内存补丁 */
static kern_return_t patchMemory(void *addr, const void *data, size_t size) {
    vm_address_t page = (vm_address_t)addr & ~(vm_page_size - 1);
    
    kern_return_t kr = vm_protect(mach_task_self(), page, vm_page_size,
                                   false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        kr = vm_protect(mach_task_self(), page, vm_page_size,
                        false, VM_PROT_ALL);
        if (kr != KERN_SUCCESS) return kr;
    }
    
    memcpy(addr, data, size);
    sys_icache_invalidate(addr, size);
    
    vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ | VM_PROT_EXECUTE);
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ applyPatches(); });
        return;
    }
    
    uint32_t patch[] = { ARM64_MOV_W0_1, ARM64_RET };
    
    void *addr1 = (void *)(base + OFF_CheckSkillAttackCanUse);
    kern_return_t kr1 = patchMemory(addr1, patch, sizeof(patch));
    
    void *addr2 = (void *)(base + OFF_CheckSkillIsReady);
    kern_return_t kr2 = patchMemory(addr2, patch, sizeof(patch));
    
    if (kr1 == KERN_SUCCESS && kr2 == KERN_SUCCESS) {
        applied = YES;
    } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ applyPatches(); });
    }
}

__attribute__((constructor))
static void initialize(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ applyPatches(); });
}