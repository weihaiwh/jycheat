/**
 * 剑影江湖 (com.jyjh.whwb) v1.8.1 - 无CD无能量技能插件
 *
 * 核心逻辑:
 *   CheckSkillAttackCanUse (0x2A9218) -> return true  绕过CD检测
 *   CheckSkillIsReady       (0x2A9B08) -> return true  绕过能量+CD检测(含大招)
 *
 * 适配: iOS 15.0+ arm64, 无根越狱 (Dopamine/Palera1n/NekoJB)
 * 设备: iPhone 13 Pro Max (iOS 15.6)
 */

#import <substrate.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>

#define LOG(fmt, args...) NSLog(@"[JYJH_NoCDNoEnergy] " fmt, ##args)

/* IL2CPP 函数偏移 (v1.8.1 dump RVA) */
static const uint64_t OFF_CheckSkillAttackCanUse = 0x2A9218;
static const uint64_t OFF_CheckSkillIsReady       = 0x2A9B08;

static uint64_t g_base = 0;
static BOOL g_installed = NO;

/* 原函数指针 */
static bool (*orig_CheckSkillAttackCanUse)(void *frame, int stateType, void *cf, void *states);
static bool (*orig_CheckSkillIsReady)(void *frame, int stateType, void *cf, void *states);

/*
 * Hook: CheckSkillAttackCanUse
 * 原型: static Boolean CheckSkillAttackCanUse(Frame, CharacterStateType, CharacterFiled*, CharacterStatesAsset)
 * 作用: 技能CD/状态可用性检查 -> 始终返回true = 无CD
 */
static bool hook_CheckSkillAttackCanUse(void *frame, int stateType, void *cf, void *states) {
    return true;
}

/*
 * Hook: CheckSkillIsReady
 * 原型: static Boolean CheckSkillIsReady(Frame, CharacterStateType, CharacterFiled*, CharacterStatesAsset)
 * 作用: 技能就绪检查(含能量/怒气) -> 始终返回true = 无能量限制
 * ★ 绕过大招能量检测的关键函数
 */
static bool hook_CheckSkillIsReady(void *frame, int stateType, void *cf, void *states) {
    return true;
}

/* 查找IL2CPP模块基址 */
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

/* 安装Hook */
static void installHooks(void) {
    if (g_installed) return;

    g_base = findModuleBase("FrameSync.code.dll");
    if (!g_base) {
        LOG(@"FrameSync.code.dll not loaded, retry in 2s...");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ installHooks(); });
        return;
    }

    LOG(@"FrameSync.code.dll base = 0x%llx", g_base);

    void *addrCanUse = (void *)(g_base + OFF_CheckSkillAttackCanUse);
    void *addrReady  = (void *)(g_base + OFF_CheckSkillIsReady);

    LOG(@"Hooking CheckSkillAttackCanUse @ %p", addrCanUse);
    LOG(@"Hooking CheckSkillIsReady       @ %p", addrReady);

    MSHookFunction(addrCanUse,
                   (void *)hook_CheckSkillAttackCanUse,
                   (void **)&orig_CheckSkillAttackCanUse);

    MSHookFunction(addrReady,
                   (void *)hook_CheckSkillIsReady,
                   (void **)&orig_CheckSkillIsReady);

    g_installed = YES;
    LOG(@"Hooks installed! NoCD + NoEnergy active.");
}

__attribute__((constructor))
static void initialize(void) {
    LOG(@"JYJH_NoCDNoEnergy v1.0 loaded");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ installHooks(); });
}
