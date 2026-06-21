/**
 * v73 - 全面反检测: 增强动态库检测对抗
 * v72: hook dyld/getenv/task_info/NSProcessInfo (不够,选角色后被检测)
 * v73新增:
 *   - hook dlopen/dlsym 隐藏注入dylib(返回NULL)
 *   - swizzle NSFileManager fileExistsAtPath 隐藏注入文件
 *   - hook fopen/access/stat 隐藏文件路径(C层)
 *   - 增加更多隐藏关键字(PlayTools, Substrate等越狱特征)
 */
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <stdio.h>
#import <string.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <objc/runtime.h>
#include "dobby.h"

// ===== 反检测: 隐藏注入dylib =====

// 前置声明jlog(因为反检测代码在jlog定义之前)
static FILE *g_logFile = NULL;
static void jlog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1,2);
static void jlog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[JYJH] %@", msg);
    if (!g_logFile) { NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/jyjh.log"]; g_logFile = fopen([p UTF8String], "a"); }
    if (g_logFile) { fprintf(g_logFile, "%s\n", [msg UTF8String]); fflush(g_logFile); }
}

// 要隐藏的dylib路径关键字(dyld image列表过滤用)
static const char *g_hiddenDylibKeywords[] = {
    "JYJH_NoCDNoEnergy",
    "NoCDNoEnergy",
    NULL
};

// 要隐藏的文件路径关键字(用于fileExistsAtPath/fopen/access等)
// 注意: 不要包含太短/太通用的关键字如"jyjh",会误杀自己的日志文件
static const char *g_hiddenFilePaths[] = {
    "JYJH_NoCDNoEnergy",
    "NoCDNoEnergy",
    "/Library/MobileSubstrate",
    "/Library/Frameworks/Cydia",
    "/usr/lib/libsubstrate",
    "/usr/lib/substrate",
    "/Applications/Cydia.app",
    "/Applications/Sileo.app",
    "/Applications/Zebra.app",
    "/usr/sbin/frida",
    "/usr/lib/libfrida",
    "frida-server",
    "/etc/apt",
    "/var/lib/cydia",
    "/var/cache/apt",
    "/usr/lib/psubstrate",
    "/.substrate_version",
    NULL
};

static BOOL shouldHideImage(const char *name) {
    if(!name) return NO;
    for(int i=0; g_hiddenDylibKeywords[i]; i++){
        if(strstr(name, g_hiddenDylibKeywords[i])) return YES;
    }
    return NO;
}

// 检查文件路径是否应该隐藏
// 注意: 跳过自己的日志文件路径,避免自杀
static BOOL shouldHidePath(const char *path) {
    if(!path) return NO;
    // 不隐藏自己的日志文件
    if(strstr(path, "jyjh.log") != NULL) return NO;
    // 不隐藏Documents目录下的文件(我们的日志在那里)
    if(strstr(path, "/Documents/") != NULL) return NO;
    // 检查注入dylib关键字
    for(int i=0; g_hiddenDylibKeywords[i]; i++){
        if(strstr(path, g_hiddenDylibKeywords[i])) return YES;
    }
    // 再检查越狱特征路径
    for(int i=0; g_hiddenFilePaths[i]; i++){
        if(strstr(path, g_hiddenFilePaths[i])) return YES;
    }
    return NO;
}

static BOOL shouldHidePathNS(NSString *path) {
    if(!path) return NO;
    const char *cpath = [path UTF8String];
    return shouldHidePath(cpath);
}

// 保存原始dyld函数指针
static uint32_t (*orig_dyld_image_count)(void) = NULL;
static const char* (*orig_dyld_get_image_name)(uint32_t) = NULL;
static const struct mach_header* (*orig_dyld_get_image_header)(uint32_t) = NULL;
static intptr_t (*orig_dyld_get_image_vmaddr_slide)(uint32_t) = NULL;
static char* (*orig_getenv)(const char*) = NULL;
static kern_return_t (*orig_task_info)(task_name_t, task_flavor_t, task_info_t, mach_msg_type_number_t*) = NULL;

// v73: 新增hook
static void* (*orig_dlopen)(const char*, int) = NULL;
static void* (*orig_dlsym)(void*, const char*) = NULL;
static int (*orig_access)(const char*, int) = NULL;
static FILE* (*orig_fopen)(const char*, const char*) = NULL;

// 构建过滤后的image索引映射表
// filteredIndices[i] = 原始image index, filteredCount = 过滤后的数量
static uint32_t *g_filteredIndices = NULL;
static uint32_t g_filteredCount = 0;
static BOOL g_dyldHooksInstalled = NO;

static void rebuildFilteredIndices(void) {
    uint32_t totalCount = orig_dyld_image_count ? orig_dyld_image_count() : 0;
    if(g_filteredIndices) { free(g_filteredIndices); g_filteredIndices = NULL; }
    g_filteredCount = 0;
    if(totalCount == 0) return;
    g_filteredIndices = (uint32_t*)malloc(totalCount * sizeof(uint32_t));
    for(uint32_t i = 0; i < totalCount; i++) {
        const char *name = orig_dyld_get_image_name ? orig_dyld_get_image_name(i) : NULL;
        if(!shouldHideImage(name)) {
            g_filteredIndices[g_filteredCount++] = i;
        }
    }
}

static uint32_t replaced_dyld_image_count(void) {
    if(!g_filteredIndices) rebuildFilteredIndices();
    return g_filteredCount;
}

static const char* replaced_dyld_get_image_name(uint32_t index) {
    if(!g_filteredIndices) rebuildFilteredIndices();
    if(index >= g_filteredCount) return NULL;
    return orig_dyld_get_image_name(g_filteredIndices[index]);
}

static const struct mach_header* replaced_dyld_get_image_header(uint32_t index) {
    if(!g_filteredIndices) rebuildFilteredIndices();
    if(index >= g_filteredCount) return NULL;
    return orig_dyld_get_image_header(g_filteredIndices[index]);
}

static intptr_t replaced_dyld_get_image_vmaddr_slide(uint32_t index) {
    if(!g_filteredIndices) rebuildFilteredIndices();
    if(index >= g_filteredCount) return 0;
    return orig_dyld_get_image_vmaddr_slide(g_filteredIndices[index]);
}

// hook getenv: 过滤掉 DYLD_INSERT_LIBRARIES 和 DYLD_LIBRARY_PATH
static char* replaced_getenv(const char *name) {
    if(name) {
        if(strcmp(name, "DYLD_INSERT_LIBRARIES") == 0 ||
           strcmp(name, "DYLD_LIBRARY_PATH") == 0) {
            return NULL; // 不存在
        }
    }
    return orig_getenv(name);
}

// hook task_info: 隐藏dyld_all_image_infos中的注入信息
// dyld_all_image_infos布局: version(uint32), infoArrayCount(uint32) at offset +4
// 注意: struct dyld_all_image_infos在macOS SDK中可能不完整, 用偏移直接操作
#define DYLD_ALL_IMAGE_INFOS_COUNT_OFFSET 4
static kern_return_t replaced_task_info(task_name_t target_task, task_flavor_t flavor, task_info_t task_info_out, mach_msg_type_number_t *task_info_outCnt) {
    kern_return_t result = orig_task_info(target_task, flavor, task_info_out, task_info_outCnt);
    if(flavor == TASK_DYLD_INFO && result == KERN_SUCCESS && task_info_out) {
        struct task_dyld_info *info = (struct task_dyld_info *)task_info_out;
        if(info->all_image_info_addr) {
            // dyld_all_image_infos.infoArrayCount at offset +4
            uint8_t *dyldInfoPtr = (uint8_t*)(uintptr_t)info->all_image_info_addr;
            if(!g_filteredIndices) rebuildFilteredIndices();
            // 覆写infoArrayCount为过滤后的数量
            uint32_t fc = g_filteredCount;
            memcpy(dyldInfoPtr + DYLD_ALL_IMAGE_INFOS_COUNT_OFFSET, &fc, sizeof(uint32_t));
        }
    }
    return result;
}

// v73: hook dlopen - 如果尝试加载我们的dylib则返回NULL
static void* replaced_dlopen(const char *path, int mode) {
    if(path && shouldHidePath(path)) {
        jlog(@"AntiDetect: blocked dlopen(\"%s\")", path);
        return NULL;
    }
    return orig_dlopen(path, mode);
}

// v73: hook dlsym - 如果在我们的dylib中查找符号则返回NULL
static void* replaced_dlsym(void *handle, const char *symbol) {
    // 不拦截正常dlsym, 但可以在这里添加对特定符号的过滤
    return orig_dlsym(handle, symbol);
}

// v73: hook access - 隐藏注入文件路径
static int replaced_access(const char *path, int mode) {
    if(shouldHidePath(path)) {
        return -1; // 文件不存在
    }
    return orig_access(path, mode);
}

// v73: hook fopen - 隐藏注入文件路径
static FILE* replaced_fopen(const char *path, const char *mode) {
    if(shouldHidePath(path)) {
        return NULL; // 文件不存在
    }
    return orig_fopen(path, mode);
}

static void installAntiDetectHooks(void) {
    if(g_dyldHooksInstalled) return;
    g_dyldHooksInstalled = YES;

    // 先读取一次原始image列表, 构建过滤索引
    // 注意: 这些hook必须在DobbyHook其他函数之前安装, 但我们用的是Dobby而不是fishhook
    // Dobby可以hook任意函数, 但需要函数地址

    // Hook dyld image API
    DobbyHook((void*)_dyld_image_count, (void*)replaced_dyld_image_count, (void**)&orig_dyld_image_count);
    DobbyHook((void*)_dyld_get_image_name, (void*)replaced_dyld_get_image_name, (void**)&orig_dyld_get_image_name);
    DobbyHook((void*)_dyld_get_image_header, (void*)replaced_dyld_get_image_header, (void**)&orig_dyld_get_image_header);
    DobbyHook((void*)_dyld_get_image_vmaddr_slide, (void*)replaced_dyld_get_image_vmaddr_slide, (void**)&orig_dyld_get_image_vmaddr_slide);

    // Hook getenv
    DobbyHook((void*)getenv, (void*)replaced_getenv, (void**)&orig_getenv);

    // Hook task_info
    DobbyHook((void*)task_info, (void*)replaced_task_info, (void**)&orig_task_info);

    // v73: Hook dlopen/dlsym - 隐藏注入dylib的动态加载
    DobbyHook((void*)dlopen, (void*)replaced_dlopen, (void**)&orig_dlopen);
    DobbyHook((void*)dlsym, (void*)replaced_dlsym, (void**)&orig_dlsym);

    // v73: Hook access/fopen - C层文件存在性检查
    DobbyHook((void*)access, (void*)replaced_access, (void**)&orig_access);
    DobbyHook((void*)fopen, (void*)replaced_fopen, (void**)&orig_fopen);

    // 构建初始过滤索引
    rebuildFilteredIndices();

    jlog(@"AntiDetect: installed dyld/getenv/task_info hooks, filtered %u/%u images",
         (unsigned)(orig_dyld_image_count ? orig_dyld_image_count() : 0) - g_filteredCount,
         (unsigned)(orig_dyld_image_count ? orig_dyld_image_count() : 0));

    // Hook NSProcessInfo.environment - 使用ObjC method swizzling
    // 因为Dobby hook ObjC方法不太方便, 用runtime swizzle
    Class psiClass = [NSProcessInfo class];
    SEL envSel = @selector(environment);
    Method origMethod = class_getInstanceMethod(psiClass, envSel);
    if(origMethod) {
        IMP origIMP = method_getImplementation(origMethod);
        IMP newIMP = imp_implementationWithBlock(^NSDictionary*(id self) {
            NSDictionary *env = ((NSDictionary*(*)(id,SEL))origIMP)(self, envSel);
            NSMutableDictionary *filtered = [env mutableCopy];
            [filtered removeObjectForKey:@"DYLD_INSERT_LIBRARIES"];
            [filtered removeObjectForKey:@"DYLD_LIBRARY_PATH"];
            [filtered removeObjectForKey:@"_MSSafeMode"];
            [filtered removeObjectForKey:@"_SafeMode"];
            [filtered removeObjectForKey:@"_SubstituteSafeMode"];
            return [filtered copy];
        });
        method_setImplementation(origMethod, newIMP);
        jlog(@"AntiDetect: swizzled NSProcessInfo.environment");
    }

    // v73: Swizzle NSFileManager fileExistsAtPath - 隐藏注入文件
    Class fmClass = [NSFileManager class];
    SEL feSel = @selector(fileExistsAtPath:);
    Method feMethod = class_getInstanceMethod(fmClass, feSel);
    if(feMethod) {
        IMP feOrigIMP = method_getImplementation(feMethod);
        IMP feNewIMP = imp_implementationWithBlock(^BOOL(id self, NSString *path) {
            if(shouldHidePathNS(path)) return NO;
            return ((BOOL(*)(id,SEL,NSString*))feOrigIMP)(self, feSel, path);
        });
        method_setImplementation(feMethod, feNewIMP);
        jlog(@"AntiDetect: swizzled NSFileManager.fileExistsAtPath:");
    }

    // v73: Swizzle NSFileManager fileExistsAtPath:isDirectory:
    SEL feiSel = @selector(fileExistsAtPath:isDirectory:);
    Method feiMethod = class_getInstanceMethod(fmClass, feiSel);
    if(feiMethod) {
        IMP feiOrigIMP = method_getImplementation(feiMethod);
        IMP feiNewIMP = imp_implementationWithBlock(^BOOL(id self, NSString *path, BOOL *isDir) {
            if(shouldHidePathNS(path)) return NO;
            return ((BOOL(*)(id,SEL,NSString*,BOOL*))feiOrigIMP)(self, feiSel, path, isDir);
        });
        method_setImplementation(feiMethod, feiNewIMP);
        jlog(@"AntiDetect: swizzled NSFileManager.fileExistsAtPath:isDirectory:");
    }

    // v73: Swizzle NSFileManager contentsOfDirectoryAtPath:error: - 从目录列表中过滤注入文件
    SEL codSel = @selector(contentsOfDirectoryAtPath:error:);
    Method codMethod = class_getInstanceMethod(fmClass, codSel);
    if(codMethod) {
        IMP codOrigIMP = method_getImplementation(codMethod);
        IMP codNewIMP = imp_implementationWithBlock(^NSArray*(id self, NSString *path, NSError **error) {
            NSArray *result = ((NSArray*(*)(id,SEL,NSString*,NSError**))codOrigIMP)(self, codSel, path, error);
            if(!result) return result;
            NSMutableArray *filtered = [NSMutableArray array];
            for(NSString *item in result) {
                if(!shouldHidePathNS(item) && !shouldHidePathNS([path stringByAppendingPathComponent:item])) {
                    [filtered addObject:item];
                }
            }
            return [filtered copy];
        });
        method_setImplementation(codMethod, codNewIMP);
        jlog(@"AntiDetect: swizzled NSFileManager.contentsOfDirectoryAtPath:error:");
    }

    // v73: Hook NSBundle bundleWithPath: / loadAndReturnError: - 隐藏注入的bundle
    Class bundleClass = [NSBundle class];
    SEL bpwSel = @selector(bundleWithPath:);
    Method bpwMethod = class_getClassMethod(bundleClass, bpwSel);
    if(bpwMethod) {
        IMP bpwOrigIMP = method_getImplementation(bpwMethod);
        IMP bpwNewIMP = imp_implementationWithBlock(^NSBundle*(id self, NSString *path) {
            if(shouldHidePathNS(path)) return nil;
            return ((NSBundle*(*)(id,SEL,NSString*))bpwOrigIMP)(self, bpwSel, path);
        });
        method_setImplementation(bpwMethod, bpwNewIMP);
        jlog(@"AntiDetect: swizzled NSBundle.bundleWithPath:");
    }

    // v73: Hook NSURL fileURLWithPath: - 隐藏注入文件的URL创建
    Class urlClass = [NSURL class];
    SEL fuSel = @selector(fileURLWithPath:);
    Method fuMethod = class_getClassMethod(urlClass, fuSel);
    if(fuMethod) {
        IMP fuOrigIMP = method_getImplementation(fuMethod);
        IMP fuNewIMP = imp_implementationWithBlock(^NSURL*(id self, NSString *path) {
            if(shouldHidePathNS(path)) return nil;
            return ((NSURL*(*)(id,SEL,NSString*))fuOrigIMP)(self, fuSel, path);
        });
        method_setImplementation(fuMethod, fuNewIMP);
        jlog(@"AntiDetect: swizzled NSURL.fileURLWithPath:");
    }

    jlog(@"AntiDetect v73: all hooks installed");
}

// ===== 原有代码 =====

static BOOL g_ignoreUnlock=NO, g_exSkillNoCD=NO, g_godMode=NO, g_fullScreen=NO;
static BOOL g_skillReplace=NO; // 技能替换总开关
static BOOL g_replaceSkill1=NO, g_replaceSkill2=NO, g_replaceSkill3=NO, g_replaceSkill4=NO, g_replaceSkill5=NO;
static int g_damageLimit=100, g_skinId=0, g_weaponId=0;
static float g_speedMul=1.0f; // v69: 移动速度倍率 1.0=正常

typedef BOOL (*BoolFunc3)(void*,int,int);
typedef int (*IntFunc1)(void*);
typedef BOOL (*BoolFunc4)(void*,int,void*,void*);
typedef BOOL (*CanBeAttackFunc)(void*);
typedef int64_t (*DamageFunc)(void*,void*,void*,void*,void*,int32_t,int32_t,BOOL,int32_t,int32_t,void*,void*);
typedef int64_t (*DecreaseHPFunc)(void*,void*,void*,void*,int64_t);
typedef BOOL (*IntersectsFunc)(void*,void*);
typedef int32_t (*CheckHitFunc)(void*,void*);
// v67: UseSkill Hook - 只替换玩家的skillStateType
typedef void (*UseSkillFunc)(void*,void*,void*,int,BOOL,void*,void*,void*);
// v66: UpdateSkillCoolDown Hook - 让大招CD归零
typedef void (*UpdateSkillCDFunc)(void*,void*,void*,void*);

static void *g_fUnlock=NULL; static BoolFunc3 g_oUnlock=NULL; static BOOL g_hUnlock=NO;
static void *g_fLimitDmg=NULL; static IntFunc1 g_oLimitDmg=NULL; static BOOL g_hLimitDmg=NO;
static void *g_fIsReady=NULL; static BoolFunc4 g_oIsReady=NULL; static BOOL g_hIsReady=NO;
static void *g_fAttackCanUse=NULL; static BoolFunc4 g_oAttackCanUse=NULL; static BOOL g_hAttackCanUse=NO;
static void *g_fCanBeAttack=NULL; static CanBeAttackFunc g_oCanBeAttack=NULL; static BOOL g_hCanBeAttack=NO;
static void *g_fDamage=NULL; static DamageFunc g_oDamage=NULL; static BOOL g_hDamage=NO;
static void *g_fIntersects=NULL; static IntersectsFunc g_oIntersects=NULL; static BOOL g_hIntersects=NO;
static void *g_fCheckHit=NULL; static CheckHitFunc g_oCheckHit=NULL; static BOOL g_hCheckHit=NO;
// v67: UseSkill Hook - 大招替换核心: 仅替换玩家(非AI)的skillStateType 14-18->19
static void *g_fUseSkill=NULL; static UseSkillFunc g_oUseSkill=NULL; static BOOL g_hUseSkill=NO;
// v66: HandleSkillRange Hook (保留诊断)
typedef void (*HandleSkillRangeFunc)(void*,void*,int32_t,void*);
static void *g_fHandleSkillRange=NULL; static HandleSkillRangeFunc g_oHandleSkillRange=NULL; static BOOL g_hHandleSkillRange=NO;
// v66: UpdateSkillCoolDown Hook - 技能替换核心: 让所有技能(含大招)CD归零
static void *g_fUpdateSkillCD=NULL; static UpdateSkillCDFunc g_oUpdateSkillCD=NULL; static BOOL g_hUpdateSkillCD=NO;

typedef void (*HitSystemUpdateFunc)(void*,void*);
static void *g_fHitSystemUpdate=NULL; static HitSystemUpdateFunc g_oHitSystemUpdate=NULL; static BOOL g_hHitSystemUpdate=NO;

static DecreaseHPFunc g_origDecreaseHP = NULL;
static void *g_classActor=NULL;

// v72: 恢复皮肤Hook - get_SkinId返回目标skinId(只改返回值,不改帧同步内存)
// v68用此方法成功,v69因写backing field导致卡死,v72只hook返回值不会卡死
static int32_t g_appliedSkinId=0, g_appliedWeaponId=0;
static void *g_fGetSkinId=NULL;
typedef int32_t (*GetSkinIdFunc)(void*);
static GetSkinIdFunc g_oGetSkinId=NULL; static BOOL g_hGetSkinId=NO;
static void *g_playerActorObj=NULL;
static int g_skinIdHookLC=0;

static int32_t hGetSkinId(void *self) {
    if(self && !g_playerActorObj) {
        g_playerActorObj=self;
        int32_t skinId=0,weaponId=0;
        memcpy(&skinId,(uint8_t*)self+0x110,4);
        memcpy(&weaponId,(uint8_t*)self+0x114,4);
        jlog(@"FOUND player Actor=%p skin=%d weapon=%d",self,skinId,weaponId);
    }
    int32_t r=g_oGetSkinId?g_oGetSkinId(self):0;
    // v72: 只hook返回值, 不写backing field(不会帧同步卡死)
    if(self==g_playerActorObj && g_appliedSkinId>0) {
        if(g_skinIdHookLC<10){g_skinIdHookLC++;jlog(@"get_SkinId: %d->%d",r,g_appliedSkinId);}
        return g_appliedSkinId;
    }
    return r;
}

// v72: MoveStep Hook - 增加参数诊断 + 放大moveDir位移向量
// MoveStep(Frame, EntityRef, CharacterFiled*, Vector2 moveDir, FP, FP, FP, Transform2D*)
// v72: 尝试两种加速方式:
//   A) 放大moveDir向量(前4参数中第4个是位移方向向量)
//   B) 修改cf->MoveSpped字段(用FP定点数格式int64)
typedef void (*MoveStepFunc)(void*,void*,void*,void*,void*,void*,void*,void*);
static void *g_fMoveStep=NULL; static MoveStepFunc g_oMoveStep=NULL; static BOOL g_hMoveStep=NO;
static int g_moveLC=0;

// 前置声明: isPlayerCF在hook中使用, 必须先定义
static BOOL isPlayerCF(void *cf) { if(!cf)return NO; int32_t v=-1; memcpy(&v,(uint8_t*)cf+0x44,4); return v==0; }
static BOOL isDeadCF(void *cf) { if(!cf)return YES; int32_t v=-1; memcpy(&v,(uint8_t*)cf+0x48,4); return v!=0; }

static int g_moveStepDiag=0;
static void hMoveStep(void *f,void *entity,void *cf,void *moveDir,void *p4,void *p5,void *p6,void *tf) {
    // v72: 诊断 - 前几次调用打印参数值
    if(g_moveStepDiag<5 && cf) {
        g_moveStepDiag++;
        int32_t isAI=1; memcpy(&isAI,(uint8_t*)cf+0x44,4);
        int64_t speed80=0,speed88=0;
        memcpy(&speed80,(uint8_t*)cf+0x80,8);
        memcpy(&speed88,(uint8_t*)cf+0x88,8);
        // moveDir可能是FPVector2 = (FP x, FP y) = (int64, int64)
        int64_t dx=0,dy=0;
        if(moveDir){memcpy(&dx,moveDir,8);memcpy(&dy,(uint8_t*)moveDir+8,8);}
        jlog(@"MoveStep[%d] cf=%p isAI=%d speed80=%lld speed88=%lld dir=(%lld,%lld)",
             g_moveStepDiag,cf,isAI,speed80,speed88,dx,dy);
    }
    
    if(g_speedMul>1.0f && cf && isPlayerCF(cf)) {
        // 方式A: 放大moveDir位移向量(FPVector2 = 两个int64)
        // FP定点数: 1.0 = 65536, 乘以speedMul直接乘int64
        if(moveDir) {
            int64_t dx=0,dy=0;
            memcpy(&dx,moveDir,8);
            memcpy(&dy,(uint8_t*)moveDir+8,8);
            int64_t ndx=(int64_t)((double)dx*g_speedMul);
            int64_t ndy=(int64_t)((double)dy*g_speedMul);
            memcpy(moveDir,&ndx,8);
            memcpy((uint8_t*)moveDir+8,&ndy,8);
            if(g_moveLC<10){g_moveLC++;jlog(@"MoveStep: dir×%.1f (%lld,%lld)->(%lld,%lld)",g_speedMul,dx,dy,ndx,ndy);}
        }
        
        // 方式B: 同时修改cf->MoveSpped(+0x80)和SpintSpped(+0x88)
        int64_t origSpeed=0;
        memcpy(&origSpeed,(uint8_t*)cf+0x80,8);
        int64_t newSpeed = (int64_t)((double)origSpeed * g_speedMul);
        memcpy((uint8_t*)cf+0x80,&newSpeed,8);
        int64_t origSprint=0;
        memcpy(&origSprint,(uint8_t*)cf+0x88,8);
        int64_t newSprint = (int64_t)((double)origSprint * g_speedMul);
        memcpy((uint8_t*)cf+0x88,&newSprint,8);
        
        if(g_oMoveStep) g_oMoveStep(f,entity,cf,moveDir,p4,p5,p6,tf);
        
        // 恢复速度字段
        memcpy((uint8_t*)cf+0x80,&origSpeed,8);
        memcpy((uint8_t*)cf+0x88,&origSprint,8);
        return;
    }
    if(g_oMoveStep) g_oMoveStep(f,entity,cf,moveDir,p4,p5,p6,tf);
}

// v62: HitSystem - 偏移已确认: collBound@0x38, Extents.X@0x48, Extents.Y@0x50
#define HITSYS_COLLBOUND_OFF 0x38
#define HITSYS_EXTENTS_X_OFF (HITSYS_COLLBOUND_OFF+0x10)  // 0x48
#define HITSYS_EXTENTS_Y_OFF (HITSYS_COLLBOUND_OFF+0x18)  // 0x50
static int64_t g_savedExtX=0, g_savedExtY=0;

static void *g_playerCF=NULL, *g_playerEntity=NULL; static BOOL g_playerCFLearned=NO;
#define MAX_ENEMIES 64
static void *g_enemyCFs[MAX_ENEMIES], *g_enemyEntities[MAX_ENEMIES]; static int g_enemyCount=0;

// v63: 皮肤扫描 - 纯内存读取(不用runtime_invoke)
static void *g_classUnityGameEntry=NULL;
static void *g_classHotfixGameEntry=NULL;
static void *g_classConfigComponent=NULL;
static void *g_classHotfixConfigComponent=NULL; // v64: HotfixFramework.Runtime (优先)
#define MAX_GAME_ENTRIES 8
static void *g_allGameEntries[MAX_GAME_ENTRIES];
static const char *g_allGameEntryNS[MAX_GAME_ENTRIES];
static int g_gameEntryCount=0;
#define MAX_SKIN_IDS 256
static int32_t g_roleSkinIds[MAX_SKIN_IDS], g_weaponSkinIds[MAX_SKIN_IDS];
static int g_roleSkinCount=0, g_weaponSkinCount=0;
static BOOL g_skinIdsLoaded=NO;

static BOOL isValidPtr(void *p) {
    if(!p) return NO;
    uint64_t v=0; memcpy(&v,&p,8);
    return (v>=0x100000000ULL && v<=0x1FFFFFFFFFFFULL);
}

// v63: 获取IL2CPP类静态数据区
static void *getStaticData(void *klass) {
    if(!klass) return NULL;
    void *h=dlopen(NULL,RTLD_LAZY);
    if(!h) return NULL;
    typedef void* (*Fn)(void*);
    Fn func=(Fn)dlsym(h,"il2cpp_class_get_static_field_data");
    if(!func) { jlog(@"getStaticData: API not found"); return NULL; }
    return func(klass);
}

// v63: 获取对象类名
static const char *getObjClassName(void *obj) {
    if(!obj) return NULL;
    void *klass=NULL;
    memcpy(&klass,(uint8_t*)obj,8);
    if(!klass) return NULL;
    void *h=dlopen(NULL,RTLD_LAZY);
    if(!h) return NULL;
    typedef const char* (*Fn)(void*);
    Fn func=(Fn)dlsym(h,"il2cpp_class_get_name");
    if(!func) return NULL;
    return func(klass);
}

// v64: 获取对象命名空间
static const char *getObjClassNamespace(void *obj) {
    if(!obj) return NULL;
    void *klass=NULL; memcpy(&klass,(uint8_t*)obj,8);
    if(!klass) return NULL;
    void *h=dlopen(NULL,RTLD_LAZY); if(!h) return NULL;
    typedef const char* (*Fn)(void*);
    Fn func=(Fn)dlsym(h,"il2cpp_class_get_namespace");
    return func ? func(klass) : NULL;
}

// v63: 方法1 - 读HotfixFramework.GameEntry._config静态字段(SD+0xa8)
static void *getConfigViaHotfixEntry(void) {
    if(!g_classHotfixGameEntry) { jlog(@"getConfigHF: class not found"); return NULL; }
    void *sd=getStaticData(g_classHotfixGameEntry);
    if(!isValidPtr(sd)) { jlog(@"getConfigHF: SD invalid=%p",sd); return NULL; }
    jlog(@"getConfigHF: HotfixGameEntry SD=%p",sd);
    for(int i=0;i<24;i++){
        uint64_t v=0; memcpy(&v,(uint8_t*)sd+i*8,8);
        if(v) jlog(@"  HFGE.SD[+0x%x]=0x%llx",i*8,v);
    }
    void *config=NULL;
    memcpy(&config,(uint8_t*)sd+0xa8,8);
    jlog(@"getConfigHF: _config at SD+0xa8 = %p",config);
    if(isValidPtr(config)) {
        const char *cn=getObjClassName(config);
        jlog(@"getConfigHF: _config class=%s",cn?cn:"null");
        return config;
    }
    return NULL;
}

// v63: 方法2 - 遍历s_GameFrameworkComponents链表找ConfigComponent
// LinkedList<T>: +0x10=head, +0x18=count(int32)
// LinkedListNode<T>: +0x10=list, +0x18=prev, +0x20=next, +0x28=item
#define LL_HEAD_OFF   0x10
#define LL_COUNT_OFF  0x18
#define LLN_LIST_OFF  0x10
#define LLN_PREV_OFF  0x18
#define LLN_NEXT_OFF  0x20
#define LLN_ITEM_OFF  0x28
// v64: 备选偏移(如果上面不对)
#define LL_HEAD_OFF2  0x18
#define LL_COUNT_OFF2 0x20
#define LLN_NEXT_OFF2 0x28
#define LLN_ITEM_OFF2 0x30

static void *getConfigViaComponentList(void) {
    if(!g_classUnityGameEntry) { jlog(@"getConfigList: class not found"); return NULL; }
    void *sd=getStaticData(g_classUnityGameEntry);
    if(!isValidPtr(sd)) { jlog(@"getConfigList: SD invalid=%p",sd); return NULL; }
    jlog(@"getConfigList: UnityGameEntry SD=%p",sd);
    void *listObj=NULL;
    memcpy(&listObj,(uint8_t*)sd+0x0,8);
    jlog(@"getConfigList: listObj=%p",listObj);
    if(!isValidPtr(listObj)) {
        jlog(@"getConfigList: list invalid, dumping SD:");
        for(int i=0;i<8;i++){
            uint64_t v=0; memcpy(&v,(uint8_t*)sd+i*8,8);
            jlog(@"  UGE.SD[+0x%x]=0x%llx",i*8,v);
        }
        return NULL;
    }
    // v65: dump listObj前128字节诊断偏移
    jlog(@"getConfigList: dumping listObj (128 bytes):");
    for(int i=0;i<16;i++){
        uint64_t v=0; memcpy(&v,(uint8_t*)listObj+i*8,8);
        jlog(@"  List[+0x%x]=0x%llx",i*8,v);
    }

    // v65: 暴力搜索 - 遍历listObj中所有有效指针, 检查类名是否为GameFrameworkComponent子类
    // v64 dump显示: +0x0, +0x10, +0x18, +0x30, +0x40, +0x50, +0x60, +0x70 都是有效指针
    // 这些可能是LinkedListNode, 也可能是直接的对象指针(数组形式)
    // 尝试: 直接把每个有效指针当作组件, 检查类名
    for(int off=0;off<128;off+=8){
        void *p=NULL; memcpy(&p,(uint8_t*)listObj+off,8);
        if(!isValidPtr(p)) continue;
        const char *cn=getObjClassName(p);
        if(!cn) continue;
        const char *ns=getObjClassNamespace(p);
        jlog(@"  ptr[+0x%x]=%p class=%s ns=%s",off,p,cn,ns?ns:"null");
        if(strcmp(cn,"ConfigComponent")==0){
            if(ns&&strstr(ns,"HotfixFramework")!=NULL){
                jlog(@"getConfigList: FOUND HotfixConfigComponent=%p at listObj+0x%x",p,off);
                return p;
            }
            jlog(@"getConfigList: found ConfigComponent=%p (ns=%s) at listObj+0x%x",p,ns?ns:"null",off);
            if(!g_classConfigComponent) g_classConfigComponent=p;
        }
    }

    // 如果直接搜索没找到, 尝试LinkedList遍历
    // v65: 从listObj+0x0开始当head, 节点布局: +0x10=list, +0x18=prev, +0x20=next, +0x28=item
    // (IL2CPP LinkedListNode有0x10 header, 所以字段从+0x10开始)
    void *headNode=NULL;
    memcpy(&headNode,(uint8_t*)listObj+0x0,8); // v65: head在+0x0
    if(isValidPtr(headNode)){
        jlog(@"getConfigList: trying LinkedList walk from head=%p",headNode);
        void *node=headNode;
        for(int i=0;i<50&&isValidPtr(node);i++){
            // dump node前64字节
            if(i<5){
                jlog(@"  node[%d]=%p dump:",i,node);
                for(int j=0;j<8;j++){
                    uint64_t v=0; memcpy(&v,(uint8_t*)node+j*8,8);
                    jlog(@"    [+0x%x]=0x%llx",j*8,v);
                }
            }
            // LinkedListNode: 尝试+0x28作为item (IL2CPP: +0x10=list,+0x18=prev,+0x20=next,+0x28=item)
            void *item=NULL;
            // 尝试多种偏移找item
            for(int itemOff=0x18;itemOff<=0x30;itemOff+=8){
                memcpy(&item,(uint8_t*)node+itemOff,8);
                if(isValidPtr(item)){
                    const char *cn=getObjClassName(item);
                    if(cn&&strcmp(cn,"ConfigComponent")==0){
                        const char *ns=getObjClassNamespace(item);
                        jlog(@"  node+0x%x item=%p class=%s ns=%s",itemOff,item,cn,ns?ns:"null");
                        if(ns&&strstr(ns,"HotfixFramework")!=NULL){
                            jlog(@"getConfigList: FOUND HotfixConfigComponent=%p",item);
                            return item;
                        }
                        if(!g_classConfigComponent) g_classConfigComponent=item;
                    }
                }
            }
            // next: 尝试+0x20
            void *nextNode=NULL;
            memcpy(&nextNode,(uint8_t*)node+0x20,8);
            if(nextNode==headNode||!isValidPtr(nextNode)) break;
            node=nextNode;
        }
    }

    // fallback
    if(g_classConfigComponent) {
        jlog(@"getConfigList: using Unity ConfigComponent as fallback");
        return g_classConfigComponent;
    }
    jlog(@"getConfigList: ConfigComponent not found");
    return NULL;
}

// v63: 获取ConfigComponent - 先试静态字段, 再试链表遍历
static void *getConfigComponent(void) {
    void *cc=getConfigViaHotfixEntry();
    if(cc) { jlog(@"getConfigComp: got via HotfixEntry=%p",cc); return cc; }
    jlog(@"getConfigComp: _config=0, trying component list...");
    cc=getConfigViaComponentList();
    if(cc) { jlog(@"getConfigComp: got via list=%p",cc); return cc; }
    jlog(@"getConfigComp: all methods failed");
    return NULL;
}

static void scanSkinIds(void) {
    if(g_skinIdsLoaded) return;
    g_roleSkinCount=0; g_weaponSkinCount=0;

    void *cc=getConfigComponent();
    if(!isValidPtr(cc)){
        jlog(@"ScanSkin: ConfigComponent NULL");
        g_skinIdsLoaded=NO;
        return;
    }

    jlog(@"ScanSkin: configComp=%p",cc);

    // ConfigComponent.<Tables>k__BackingField at +0x28 (class field, dump=actual)
    void *tables_l=NULL;
    memcpy(&tables_l,(uint8_t*)cc+0x28,8);
    jlog(@"ScanSkin: tables=%p",tables_l);
    if(!isValidPtr(tables_l)){
        jlog(@"ScanSkin: tables invalid, dumping ConfigComponent:");
        for(int i=0;i<12;i++){
            uint64_t v=0; memcpy(&v,(uint8_t*)cc+i*8,8);
            jlog(@"  CC[+0x%x]=0x%llx",i*8,v);
        }
        g_skinIdsLoaded=NO;
        return;
    }

    // Tables.TbRoleSkin at +0x230 (class field, dump=actual)
    void *tbRoleSkin=NULL;
    memcpy(&tbRoleSkin,(uint8_t*)tables_l+0x230,8);
    jlog(@"ScanSkin: tbRoleSkin=%p",tbRoleSkin);
    if(!isValidPtr(tbRoleSkin)){
        jlog(@"ScanSkin: TbRoleSkin invalid, dumping Tables valid ptrs:");
        for(int i=0;i<80;i++){
            uint64_t v=0; memcpy(&v,(uint8_t*)tables_l+i*8,8);
            if(isValidPtr((void*)v)){
                jlog(@"  Tables[0x%x]=%p",i*8,(void*)v);
            }
        }
        g_skinIdsLoaded=NO;
        return;
    }

    // TbRoleSkin._dataList at +0x18 (class field, dump=actual)
    void *dataList=NULL;
    memcpy(&dataList,(uint8_t*)tbRoleSkin+0x18,8);
    jlog(@"ScanSkin: dataList=%p",dataList);
    if(!isValidPtr(dataList)){jlog(@"ScanSkin: _dataList ptr invalid");g_skinIdsLoaded=NO;return;}

    // v66: dump dataList内存诊断List<T>偏移
    jlog(@"ScanSkin: dumping dataList (96 bytes):");
    for(int i=0;i<12;i++){
        uint64_t v=0; memcpy(&v,(uint8_t*)dataList+i*8,8);
        jlog(@"  DL[+0x%x]=0x%llx",i*8,v);
    }

    // v66: List<T>泛型dump偏移全0x0不可靠, 暴力搜索
    // IL2CPP List<T>内存: +0x00=Il2CppObject(16B header), +0x10=_items(array*), +0x18=_size(int32), +0x1c=_version
    // 但实际偏移可能不同, 需要搜索: 找到有效数组指针+合理size
    void *itemsArray=NULL; int32_t listSize=0;
    // 尝试多种_items偏移
    for(int itemsOff=0x10;itemsOff<=0x28;itemsOff+=8){
        void *testArr=NULL; int32_t testSize=0;
        memcpy(&testArr,(uint8_t*)dataList+itemsOff,8);
        // size在items后面4字节
        int sizeOff=itemsOff+8;
        if(sizeOff+4<=96) memcpy(&testSize,(uint8_t*)dataList+sizeOff,4);
        if(isValidPtr(testArr)&&testSize>0&&testSize<10000){
            // 验证: 检查testArr是否像IL2CPP数组(有klass指针, 有max_length)
            int32_t testArrLen=0;
            // IL2CPP数组: +0x18=max_length (标准偏移)
            memcpy(&testArrLen,(uint8_t*)testArr+0x18,4);
            if(testArrLen>=testSize&&testArrLen<100000){
                jlog(@"ScanSkin: found List at itemsOff=+0x%x sizeOff=+0x%x arr=%p size=%d arrLen=%d",
                     itemsOff,sizeOff,testArr,testSize,testArrLen);
                itemsArray=testArr; listSize=testSize;
                break;
            }
            // 也试+0x10作为max_length
            memcpy(&testArrLen,(uint8_t*)testArr+0x10,4);
            if(testArrLen>=testSize&&testArrLen<100000){
                jlog(@"ScanSkin: found List at itemsOff=+0x%x (arrLen@+0x10) arr=%p size=%d arrLen=%d",
                     itemsOff,testArr,testSize,testArrLen);
                itemsArray=testArr; listSize=testSize;
                break;
            }
        }
    }
    jlog(@"ScanSkin: itemsArray=%p listSize=%d",itemsArray,listSize);
    if(!itemsArray||listSize<=0||!isValidPtr(itemsArray)){jlog(@"ScanSkin: List empty or invalid");g_skinIdsLoaded=NO;return;}

    // v66: IL2CPP数组 max_length 在 +0x18 (标准偏移)
    int32_t arrayLen=0;
    memcpy(&arrayLen,(uint8_t*)itemsArray+0x18,4);
    jlog(@"ScanSkin: arrayLen=%d (at +0x18)",arrayLen);
    // 如果+0x18不对, 也试+0x10
    if(arrayLen<=0||arrayLen>100000){
        int32_t altLen=0;
        memcpy(&altLen,(uint8_t*)itemsArray+0x10,4);
        jlog(@"ScanSkin: arrayLen at +0x10=%d",altLen);
        if(altLen>0&&altLen<100000) arrayLen=altLen;
    }

    int maxScan=(listSize<MAX_SKIN_IDS)?listSize:MAX_SKIN_IDS;
    for(int i=0;i<maxScan&&i<arrayLen;i++){
        void *roleSkinPtr=NULL;
        // v66: IL2CPP数组data从+0x20开始(标准偏移: +0x00=header(16B), +0x10=klass, +0x18=max_length, +0x20=data[0])
        memcpy(&roleSkinPtr,(uint8_t*)itemsArray+0x20+i*8,8);
        if(!roleSkinPtr)continue;
        // RoleSkin.Id at +0x10 (class field, dump=actual, 有0x10 header)
        int32_t skinId=0;
        memcpy(&skinId,(uint8_t*)roleSkinPtr+0x10,4);
        if(skinId>0) g_roleSkinIds[g_roleSkinCount++]=skinId;
    }
    g_skinIdsLoaded=YES;
    jlog(@"ScanSkinIds: found %d role skin IDs",g_roleSkinCount);
    for(int i=0;i<g_roleSkinCount&&i<20;i++) jlog(@"  RoleSkin[%d]=%d",i,g_roleSkinIds[i]);

    // 同样读取TbWeaponSkin
    void *tbWeaponSkin=NULL;
    memcpy(&tbWeaponSkin,(uint8_t*)tables_l+0x248,8);
    if(isValidPtr(tbWeaponSkin)){
        void *wDataList=NULL;
        memcpy(&wDataList,(uint8_t*)tbWeaponSkin+0x18,8);
        if(isValidPtr(wDataList)){
            // v66: 同样暴力搜索List偏移
            void *wItemsArray=NULL; int32_t wListSize=0;
            for(int itemsOff=0x10;itemsOff<=0x28;itemsOff+=8){
                void *testArr=NULL; int32_t testSize=0;
                memcpy(&testArr,(uint8_t*)wDataList+itemsOff,8);
                int sizeOff=itemsOff+8;
                if(sizeOff+4<=96) memcpy(&testSize,(uint8_t*)wDataList+sizeOff,4);
                if(isValidPtr(testArr)&&testSize>0&&testSize<10000){
                    int32_t testArrLen=0;
                    memcpy(&testArrLen,(uint8_t*)testArr+0x18,4);
                    if(testArrLen>=testSize&&testArrLen<100000){
                        wItemsArray=testArr; wListSize=testSize; break;
                    }
                    memcpy(&testArrLen,(uint8_t*)testArr+0x10,4);
                    if(testArrLen>=testSize&&testArrLen<100000){
                        wItemsArray=testArr; wListSize=testSize; break;
                    }
                }
            }
            if(wItemsArray&&wListSize>0){
                int32_t wArrLen=0;
                memcpy(&wArrLen,(uint8_t*)wItemsArray+0x18,4);
                if(wArrLen<=0||wArrLen>100000){memcpy(&wArrLen,(uint8_t*)wItemsArray+0x10,4);}
                int wMax=(wListSize<MAX_SKIN_IDS)?wListSize:MAX_SKIN_IDS;
                for(int i=0;i<wMax&&i<wArrLen;i++){
                    void *wsPtr=NULL;
                    memcpy(&wsPtr,(uint8_t*)wItemsArray+0x20+i*8,8);
                    if(!wsPtr)continue;
                    int32_t wId=0;
                    memcpy(&wId,(uint8_t*)wsPtr+0x10,4);
                    if(wId>0) g_weaponSkinIds[g_weaponSkinCount++]=wId;
                }
            }
        }
    }
    jlog(@"ScanSkinIds: found %d weapon skin IDs",g_weaponSkinCount);
    for(int i=0;i<g_weaponSkinCount&&i<20;i++) jlog(@"  WeaponSkin[%d]=%d",i,g_weaponSkinIds[i]);
}

static void trackEnemy(void *cf, void *ent) {
    if(!cf||!ent||isPlayerCF(cf))return;
    for(int i=0;i<g_enemyCount;i++) if(g_enemyCFs[i]==cf){g_enemyEntities[i]=ent;return;}
    if(g_enemyCount<MAX_ENEMIES){g_enemyCFs[g_enemyCount]=cf;g_enemyEntities[g_enemyCount]=ent;g_enemyCount++;}
}

// ===== Hooks =====
static int g_unlockLC=0;
static BOOL hUnlock(void *s,int a1,int a2){if(g_ignoreUnlock){if(g_unlockLC<5){g_unlockLC++;}return YES;}return g_oUnlock?g_oUnlock(s,a1,a2):YES;}
static int g_isReadyLC=0;
static BOOL hIsReady(void *f,int st,void *cf,void *st2){
    if(cf){if(isPlayerCF(cf)){if(!g_playerCFLearned){g_playerCF=cf;g_playerCFLearned=YES;jlog(@"PlayerCF=%p",cf);}}else trackEnemy(cf,NULL);}
    // v69: 技能替换开启时, 所有14-19技能都返回YES(确保都能释放)
    // UseSkill只替换选中的, 未选中的正常释放
    if(g_skillReplace&&st>=14&&st<=19){if(g_isReadyLC<30){g_isReadyLC++;jlog(@"IsReady: st=%d->YES",st);}return YES;}
    if(g_exSkillNoCD&&st>=17){if(g_isReadyLC<30)g_isReadyLC++;return YES;}
    return g_oIsReady?g_oIsReady(f,st,cf,st2):YES;
}
static int g_attackLC=0;
static BOOL hAttackCanUse(void *f,int st,void *cf,void *st2){
    if(cf&&isPlayerCF(cf)&&!g_playerCFLearned){g_playerCF=cf;g_playerCFLearned=YES;}
    // v69: 同IsReady逻辑 - 所有技能可用
    if(g_skillReplace&&st>=14&&st<=19){if(g_attackLC<30){g_attackLC++;jlog(@"AttackCanUse: st=%d->YES",st);}return YES;}
    if(g_exSkillNoCD&&st>=17){if(g_attackLC<30)g_attackLC++;return YES;}
    return g_oAttackCanUse?g_oAttackCanUse(f,st,cf,st2):YES;
}
static int hLimitDmg(void *s){return g_damageLimit;}
static int g_canBeAtkLC=0;
static BOOL hCanBeAttack(void *cf){
    if(cf){if(isPlayerCF(cf)&&g_godMode){if(g_canBeAtkLC<20)g_canBeAtkLC++;return NO;}else if(!isPlayerCF(cf))trackEnemy(cf,NULL);}
    return g_oCanBeAttack?g_oCanBeAttack(cf):YES;
}
static int g_dmgLC=0;
static int64_t hDamage(void *f,void *atkEnt,void *atkCF,void *tgtEnt,void *tgtCF,
    int32_t hitEid,int32_t hitSnd,BOOL isR,int32_t sBtn,int32_t sPart,void *hurtF,void *exS){
    BOOL tgtP=(tgtCF&&isPlayerCF(tgtCF)), atkP=(atkCF&&isPlayerCF(atkCF));
    if(atkP&&atkEnt)g_playerEntity=atkEnt;
    if(tgtCF&&!tgtP&&tgtEnt)trackEnemy(tgtCF,tgtEnt);
    if(g_godMode&&tgtP){if(g_dmgLC<20){g_dmgLC++;jlog(@"Dmg:Player->0");}return 0;}
    // v65: skillButton不是枚举(14-19), 是内部编号, 不替换
    // 只记录sBtn用于诊断
    if(g_skillReplace&&atkP){if(g_dmgLC<30){g_dmgLC++;jlog(@"Dmg[%d]=%d sBtn=%d enemies=%d",g_dmgLC,0,sBtn,g_enemyCount);}}
    if(!g_oDamage)return 0;
    int64_t r=g_oDamage(f,atkEnt,atkCF,tgtEnt,tgtCF,hitEid,hitSnd,isR,sBtn,sPart,hurtF,exS);
    if(atkP&&r>0){if(g_dmgLC<20){g_dmgLC++;jlog(@"Dmg[%d]=%lld enemies=%d sBtn=%d",g_dmgLC,r,g_enemyCount,sBtn);}}
    return r;
}
static BOOL hIntersects(void *s,void *o){if(g_fullScreen)return YES;return g_oIntersects?g_oIntersects(s,o):NO;}
static int32_t hCheckHit(void *f,void *cb){if(g_fullScreen)return 1;return g_oCheckHit?g_oCheckHit(f,cb):0;}

// v68: UseSkill Hook - 大招替换核心, 单技能选择
static int g_useSkillLC=0;
static void hUseSkill(void *f,void *entity,void *cf,int skillStateType,BOOL isRight,void *states,void *state,void *playerInfo) {
    if(g_skillReplace && skillStateType>=14 && skillStateType<=18) {
        BOOL isPlayer = NO;
        if(cf) {
            int32_t isAI=1; memcpy(&isAI,(uint8_t*)cf+0x44,4);
            isPlayer = (isAI==0);
        }
        if(isPlayer) {
            // v68: 只替换用户选择的技能
            BOOL shouldReplace = NO;
            if(skillStateType==14 && g_replaceSkill1) shouldReplace=YES;
            if(skillStateType==15 && g_replaceSkill2) shouldReplace=YES;
            if(skillStateType==16 && g_replaceSkill3) shouldReplace=YES;
            if(skillStateType==17 && g_replaceSkill4) shouldReplace=YES;
            if(skillStateType==18 && g_replaceSkill5) shouldReplace=YES;
            if(shouldReplace) {
                if(g_useSkillLC<30){g_useSkillLC++;jlog(@"UseSkill: player st=%d->19",skillStateType);}
                skillStateType=19;
            }
        }
    }
    if(g_oUseSkill) g_oUseSkill(f,entity,cf,skillStateType,isRight,states,state,playerInfo);
}

// v67: HandleSkillRange Hook - 诊断用
static int g_hsrLC=0;
static void hHandleSkillRange(void *f,void *cf,int32_t skillButton,void *exSkill) {
    if(g_skillReplace){
        if(g_hsrLC<20){g_hsrLC++;jlog(@"HSR: skillBtn=%d (orig)",skillButton);}
    }
    if(g_oHandleSkillRange) g_oHandleSkillRange(f,cf,skillButton,exSkill);
}

// v66: UpdateSkillCoolDown Hook - 技能替换核心: 让CD归零
// AttackSystem.UpdateSkillCoolDown(Frame, EntityRef, CharacterFiled*, CharacterStatesAsset)
// 当技能替换开启时, 跳过CD更新(不调用原函数), 让所有技能CD保持0
static int g_uscdLC=0;
static void hUpdateSkillCD(void *f,void *er,void *cf,void *states) {
    if(g_skillReplace) {
        // 技能替换模式: 跳过CD更新, 让所有技能随时可用
        if(g_uscdLC<20){g_uscdLC++;jlog(@"UpdateSkillCD: skipped (replace mode)");}
        return; // 不调用原函数, CD不更新
    }
    if(g_oUpdateSkillCD) g_oUpdateSkillCD(f,er,cf,states);
}

// v62: HitSystem.Update Hook - 确认偏移, 直接修改Extents
static int g_hitSysLC=0;
static void hHitSystemUpdate(void *self, void *framePtr) {
    if(!self) { if(g_oHitSystemUpdate) g_oHitSystemUpdate(self, framePtr); return; }

    // 首次调用时dump内存确认
    if(g_hitSysLC<3) {
        g_hitSysLC++;
        uint8_t *p=(uint8_t*)self;
        jlog(@"HitSys[%d] self=%p:", g_hitSysLC, self);
        for(int i=0;i<16;i++){
            int64_t v=0; memcpy(&v,p+i*8,8);
            jlog(@"  [+0x%x]=%lld(0x%llx)",i*8,v,v);
        }
    }

    if(!g_fullScreen) {
        if(g_oHitSystemUpdate) g_oHitSystemUpdate(self, framePtr);
        return;
    }
    // 保存原始Extents值
    uint8_t *p=(uint8_t*)self;
    memcpy(&g_savedExtX, p+HITSYS_EXTENTS_X_OFF, 8);
    memcpy(&g_savedExtY, p+HITSYS_EXTENTS_Y_OFF, 8);
    // 设为超大值 (直接修改, 不管原来是否为0 - v61误判为0是因为FP值看起来小)
    int64_t huge=0x7FFFFFFFFFFFFFFF;
    memcpy(p+HITSYS_EXTENTS_X_OFF, &huge, 8);
    memcpy(p+HITSYS_EXTENTS_Y_OFF, &huge, 8);
    // 调用原始Update
    if(g_oHitSystemUpdate) g_oHitSystemUpdate(self, framePtr);
    // 恢复
    memcpy(p+HITSYS_EXTENTS_X_OFF, &g_savedExtX, 8);
    memcpy(p+HITSYS_EXTENTS_Y_OFF, &g_savedExtY, 8);
}

// ===== IL2CPP Search =====
typedef void* (*Il2CppDomainGet)(void);
typedef void** (*Il2CppDomainGetAssemblies)(void*,size_t*);
typedef void* (*Il2CppAssemblyGetImage)(void*);
typedef size_t (*Il2CppImageGetClassCount)(void*);
typedef void* (*Il2CppImageGetClass)(void*,size_t);
typedef void* (*Il2CppClassGetMethods)(void*,void**);
typedef const char* (*Il2CppMethodGetName)(void*);
typedef uint32_t (*Il2CppMethodGetParamCount)(void*);
typedef const char* (*Il2CppClassGetName)(void*);
typedef const char* (*Il2CppClassGetNamespace)(void*);

static void findIL2CPP(void) {
    jlog(@"=== v72.0 IL2CPP Search ===");
    void *h=dlopen(NULL,RTLD_LAZY); if(!h){jlog(@"dlopen FAIL");return;}
    Il2CppDomainGet domain_get=dlsym(h,"il2cpp_domain_get");
    Il2CppDomainGetAssemblies get_assemblies=dlsym(h,"il2cpp_domain_get_assemblies");
    Il2CppAssemblyGetImage get_image=dlsym(h,"il2cpp_assembly_get_image");
    Il2CppImageGetClassCount class_count=dlsym(h,"il2cpp_image_get_class_count");
    Il2CppImageGetClass get_class=dlsym(h,"il2cpp_image_get_class");
    Il2CppClassGetMethods get_methods=dlsym(h,"il2cpp_class_get_methods");
    Il2CppMethodGetName method_name=dlsym(h,"il2cpp_method_get_name");
    Il2CppMethodGetParamCount param_count=dlsym(h,"il2cpp_method_get_param_count");
    Il2CppClassGetName class_name_func=dlsym(h,"il2cpp_class_get_name");
    Il2CppClassGetNamespace class_get_namespace=dlsym(h,"il2cpp_class_get_namespace");
    if(!domain_get||!method_name){jlog(@"IL2CPP APIs not found");return;}
    void *domain=domain_get(); if(!domain)return;
    size_t assemCount=0; void **assemblies=get_assemblies(domain,&assemCount);
    if(!assemblies)return;
    jlog(@"assemblies=%p count=%zu",assemblies,assemCount);
    int found=0,totalMethods=0;
    for(size_t a=0;a<assemCount;a++){
        void *img=get_image(assemblies[a]); if(!img)continue;
        size_t cnt=class_count?class_count(img):0;
        for(size_t c=0;c<cnt;c++){
            void *klass=get_class(img,c); if(!klass)continue;
            const char *cn=class_name_func?class_name_func(klass):NULL;
            const char *ns=class_get_namespace?class_get_namespace(klass):NULL;
            if(cn&&strcmp(cn,"Actor")==0&&!g_classActor){
                g_classActor=klass; jlog(@"FOUND class Actor=%p",klass);
            }
            // v64: 搜索所有GameEntry类(放宽条件,记录所有匹配)
            if(cn&&strcmp(cn,"GameEntry")==0&&g_gameEntryCount<MAX_GAME_ENTRIES){
                g_allGameEntries[g_gameEntryCount]=klass;
                g_allGameEntryNS[g_gameEntryCount]=ns?strdup(ns):NULL;
                g_gameEntryCount++;
                jlog(@"FOUND GameEntry[%d]=%p (ns=%s)",g_gameEntryCount-1,klass,ns?ns:"null");
                if(ns&&strcmp(ns,"UnityGameFramework.Runtime")==0&&!g_classUnityGameEntry){
                    g_classUnityGameEntry=klass;
                }
                if(ns&&strcmp(ns,"HotfixFramework.Runtime")==0&&!g_classHotfixGameEntry){
                    g_classHotfixGameEntry=klass;
                }
                // v64: 也检查ns为空或其他值的情况
                if(!g_classHotfixGameEntry&&!ns){
                    // 命名空间为空的GameEntry可能是Hotfix的
                    jlog(@"  GameEntry with null ns, might be HotfixFramework");
                }
            }
            // v64: 区分两个ConfigComponent
            if(cn&&strcmp(cn,"ConfigComponent")==0){
                if(ns&&strcmp(ns,"HotfixFramework.Runtime")==0&&!g_classHotfixConfigComponent){
                    g_classHotfixConfigComponent=klass; jlog(@"FOUND HotfixConfigComponent=%p (ns=%s)",klass,ns);
                }
                if(ns&&strcmp(ns,"UnityGameFramework.Runtime")==0&&!g_classConfigComponent){
                    g_classConfigComponent=klass; jlog(@"FOUND UnityConfigComponent=%p (ns=%s)",klass,ns);
                }
                if(!ns&&!g_classConfigComponent){
                    g_classConfigComponent=klass; jlog(@"FOUND ConfigComponent=%p (ns=null)",klass);
                }
            }
            void *iter=NULL,*m=NULL;
            while((m=get_methods(klass,&iter))!=NULL){
                totalMethods++;
                const char *n=method_name(m); if(!n)continue;
                uint32_t pc=param_count?param_count(m):0;
                void *fa=NULL; memcpy(&fa,m,sizeof(void*));
                if(strcmp(n,"CheckSkillUnlock")==0&&!g_fUnlock){g_fUnlock=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"get_limitDamage")==0&&!g_fLimitDmg){g_fLimitDmg=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"CheckSkillIsReady")==0&&!g_fIsReady){g_fIsReady=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"CheckSkillAttackCanUse")==0&&!g_fAttackCanUse){g_fAttackCanUse=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"CanBeAttack")==0&&!g_fCanBeAttack){g_fCanBeAttack=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"Damage")==0&&pc>=10&&!g_fDamage){g_fDamage=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"DecreaseHP")==0&&pc==5){if(!g_origDecreaseHP){g_origDecreaseHP=(DecreaseHPFunc)fa;jlog(@"FOUND DecreaseHP %p (saved)",fa);}}
                else if(strcmp(n,"Intersects")==0&&pc==1&&cn&&strstr(cn,"FPBounds2")!=NULL&&!g_fIntersects){g_fIntersects=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"CheckPlayerHitCollider")==0&&pc==2&&!g_fCheckHit){g_fCheckHit=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                else if(strcmp(n,"Update")==0&&pc==1&&cn&&strcmp(cn,"HitSystem")==0&&!g_fHitSystemUpdate){g_fHitSystemUpdate=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                // v72: 恢复get_SkinId Hook(只改返回值不改backing field, 不会卡死)
                else if(strcmp(n,"get_SkinId")==0&&pc==0&&cn&&strcmp(cn,"Actor")==0&&!g_fGetSkinId){g_fGetSkinId=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                // v65: HandleSkillRange - 放宽搜索条件(pc>=3)
                else if(strcmp(n,"HandleSkillRange")==0&&pc>=3&&!g_fHandleSkillRange){g_fHandleSkillRange=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
                // v67: UseSkill - Hook替换玩家skillStateType 14-18->19
                else if(strcmp(n,"UseSkill")==0&&pc>=7&&cn&&strcmp(cn,"AttackSystem")==0&&!g_fUseSkill){g_fUseSkill=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn,n,pc,fa);}
                // v66: UpdateSkillCoolDown - 技能替换核心: 跳过CD更新让大招随时可用
                // v69: UpdateSkillCoolDown
                else if(strcmp(n,"UpdateSkillCoolDown")==0&&pc>=3&&cn&&strcmp(cn,"AttackSystem")==0&&!g_fUpdateSkillCD){g_fUpdateSkillCD=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn,n,pc,fa);}
                // v71: MoveStep - 移动加速Hook(修改cf->MoveSpped字段)
                else if(strcmp(n,"MoveStep")==0&&pc>=7&&!g_fMoveStep){g_fMoveStep=fa;found++;jlog(@"FOUND %s.%s p=%u %p",cn?:"?",n,pc,fa);}
            }
        }
    }
    // v65: 尝试null ns的GameEntry作为HotfixGameEntry (ns=""可能是HotfixFramework)
    if(!g_classHotfixGameEntry){
        for(int i=0;i<g_gameEntryCount;i++){
            if(g_allGameEntryNS[i]==NULL||strcmp(g_allGameEntryNS[i],"")==0){
                g_classHotfixGameEntry=g_allGameEntries[i];
                jlog(@"v69: assume GameEntry[%d] ns=empty is HotfixGameEntry=%p",i,g_allGameEntries[i]);
                break;
            }
        }
    }
    jlog(@"v69: UnityGameEntry=%p HotfixGameEntry=%p",g_classUnityGameEntry,g_classHotfixGameEntry);
    jlog(@"Scanned %d methods, found %d targets, origDecreaseHP=%p",totalMethods,found,g_origDecreaseHP);
}

static void hookOneFunc(void *fa,void *hf,void **of,BOOL *hf2,const char *name){
    if(!fa){jlog(@"%s: not found",name);return;}
    if(*hf2){jlog(@"%s: already hooked",name);return;}
    int r=DobbyHook(fa,hf,of);
    if(r==0){*hf2=YES;jlog(@"%s: OK at %p orig=%p",name,fa,*of);}
    else jlog(@"%s: FAILED ret=%d",name,r);
}

static void applyAllHooks(void){if(!g_fLimitDmg)findIL2CPP();hookOneFunc(g_fLimitDmg,hLimitDmg,(void**)&g_oLimitDmg,&g_hLimitDmg,"limitDmg");jlog(@"applyAllHooks done");}

// ===== UI =====
static UIView *g_panel=nil, *g_titleBar=nil;
static UIScrollView *g_scrollView=nil;
static UIButton *g_btnIgnoreUnlock=nil,*g_btnExSkillNoCD=nil,*g_btnGodMode=nil,*g_btnFullScreen=nil,*g_btnSkillReplace=nil,*g_btnApplySkin=nil,*g_btnScanSkin=nil;
static UIButton *g_btnRepS1=nil,*g_btnRepS2=nil,*g_btnRepS3=nil,*g_btnRepS4=nil,*g_btnRepS5=nil;
static UISlider *g_slider=nil,*g_skinSlider=nil,*g_weaponSlider=nil,*g_speedSlider=nil;
static UILabel *g_sliderLabel=nil,*g_skinLabel=nil,*g_weaponLabel=nil,*g_speedLabel=nil;
static BOOL g_panelOpen=NO;
static CGFloat g_panelW=360, g_panelH=600;
static UIView *g_resizeHandle=nil, *g_resizeHandleTop=nil;

#define IMGUI_BG [UIColor colorWithRed:0.09 green:0.09 blue:0.12 alpha:0.96]
#define IMGUI_TITLE_BG [UIColor colorWithRed:0.04 green:0.04 blue:0.06 alpha:1.0]
#define IMGUI_ACCENT [UIColor colorWithRed:0.40 green:0.68 blue:1.00 alpha:1.0]
#define IMGUI_GREEN [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0]
#define IMGUI_RED [UIColor colorWithRed:0.78 green:0.20 blue:0.20 alpha:1.0]
#define IMGUI_TEXT [UIColor colorWithRed:0.90 green:0.90 blue:0.92 alpha:1.0]
#define IMGUI_DIMTEXT [UIColor colorWithRed:0.55 green:0.55 blue:0.60 alpha:1.0]
#define IMGUI_BALL_BG [UIColor colorWithRed:0.12 green:0.28 blue:0.58 alpha:0.92]
#define IMGUI_BTN_ON [UIColor colorWithRed:0.16 green:0.52 blue:0.28 alpha:0.95]
#define IMGUI_BTN_OFF [UIColor colorWithRed:0.52 green:0.14 blue:0.14 alpha:0.95]
#define IMGUI_BORDER [UIColor colorWithRed:0.25 green:0.25 blue:0.30 alpha:0.8]

@interface JYJHActionHandler:NSObject
+(instancetype)shared;
-(void)onIgnoreUnlock;-(void)onExSkillNoCD;-(void)onGodMode;-(void)onFullScreen;-(void)onSkillReplace;
-(void)onReplaceS1;-(void)onReplaceS2;-(void)onReplaceS3;-(void)onReplaceS4;-(void)onReplaceS5;
-(void)speedSliderChanged:(UISlider*)s; // v69
-(void)onApplySkin;
-(void)sliderChanged:(UISlider*)s;-(void)skinSliderChanged:(UISlider*)s;-(void)weaponSliderChanged:(UISlider*)s;
-(void)onDumpSkinIds;
@end

static UIButton* mkBtn(CGRect f,SEL a){
    UIButton *b=[UIButton buttonWithType:UIButtonTypeCustom];
    b.frame=f;b.layer.cornerRadius=4;b.layer.borderWidth=1;b.layer.borderColor=IMGUI_BORDER.CGColor;
    b.titleLabel.font=[UIFont boldSystemFontOfSize:13];b.titleLabel.textColor=IMGUI_TEXT;
    [b addTarget:[JYJHActionHandler shared] action:a forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static void refreshBtns(void){
    if(g_ignoreUnlock){[g_btnIgnoreUnlock setTitle:@"ON  \xe5\xbf\xbd\xe7\x95\xa5\xe8\xa7\xa3\xe9\x94\x81" forState:UIControlStateNormal];g_btnIgnoreUnlock.backgroundColor=IMGUI_BTN_ON;g_btnIgnoreUnlock.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnIgnoreUnlock setTitle:@"OFF \xe5\xbf\xbd\xe7\x95\xa5\xe8\xa7\xa3\xe9\x94\x81" forState:UIControlStateNormal];g_btnIgnoreUnlock.backgroundColor=IMGUI_BTN_OFF;g_btnIgnoreUnlock.layer.borderColor=IMGUI_RED.CGColor;}
    if(g_exSkillNoCD){[g_btnExSkillNoCD setTitle:@"ON  \xe6\x8a\x80\xe8\x83\xbd\xe6\x97" "\xa0" "CD" forState:UIControlStateNormal];g_btnExSkillNoCD.backgroundColor=IMGUI_BTN_ON;g_btnExSkillNoCD.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnExSkillNoCD setTitle:@"OFF \xe6\x8a\x80\xe8\x83\xbd\xe6\x97" "\xa0" "CD" forState:UIControlStateNormal];g_btnExSkillNoCD.backgroundColor=IMGUI_BTN_OFF;g_btnExSkillNoCD.layer.borderColor=IMGUI_RED.CGColor;}
    if(g_godMode){[g_btnGodMode setTitle:@"ON  \xe7\x8e\xa9\xe5\xae\xb6\xe4\xb8\x8d\xe6\xad\xbb" forState:UIControlStateNormal];g_btnGodMode.backgroundColor=IMGUI_BTN_ON;g_btnGodMode.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnGodMode setTitle:@"OFF \xe7\x8e\xa9\xe5\xae\xb6\xe4\xb8\x8d\xe6\xad\xbb" forState:UIControlStateNormal];g_btnGodMode.backgroundColor=IMGUI_BTN_OFF;g_btnGodMode.layer.borderColor=IMGUI_RED.CGColor;}
    if(g_fullScreen){[g_btnFullScreen setTitle:@"ON  \xe5\x85\xa8\xe5\xb1\x8f\xe7\xa7\x92\xe6\x9d\x80" forState:UIControlStateNormal];g_btnFullScreen.backgroundColor=IMGUI_BTN_ON;g_btnFullScreen.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnFullScreen setTitle:@"OFF \xe5\x85\xa8\xe5\xb1\x8f\xe7\xa7\x92\xe6\x9d\x80" forState:UIControlStateNormal];g_btnFullScreen.backgroundColor=IMGUI_BTN_OFF;g_btnFullScreen.layer.borderColor=IMGUI_RED.CGColor;}
    if(g_skillReplace){[g_btnSkillReplace setTitle:@"ON  \xe6\x8a\x80\xe8\x83\xbd\xe6\x9b\xbf\xe6\x8d\xa2" forState:UIControlStateNormal];g_btnSkillReplace.backgroundColor=IMGUI_BTN_ON;g_btnSkillReplace.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnSkillReplace setTitle:@"OFF \xe6\x8a\x80\xe8\x83\xbd\xe6\x9b\xbf\xe6\x8d\xa2" forState:UIControlStateNormal];g_btnSkillReplace.backgroundColor=IMGUI_BTN_OFF;g_btnSkillReplace.layer.borderColor=IMGUI_RED.CGColor;}
    // v68: 单技能替换按钮
    if(g_replaceSkill1){[g_btnRepS1 setTitle:@"1\xE2\x86\x92\xe5\xa4\xa7" forState:UIControlStateNormal];g_btnRepS1.backgroundColor=IMGUI_BTN_ON;g_btnRepS1.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnRepS1 setTitle:@"1" forState:UIControlStateNormal];g_btnRepS1.backgroundColor=[UIColor colorWithRed:0.15 green:0.15 blue:0.18 alpha:0.95];g_btnRepS1.layer.borderColor=IMGUI_BORDER.CGColor;}
    if(g_replaceSkill2){[g_btnRepS2 setTitle:@"2\xE2\x86\x92\xe5\xa4\xa7" forState:UIControlStateNormal];g_btnRepS2.backgroundColor=IMGUI_BTN_ON;g_btnRepS2.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnRepS2 setTitle:@"2" forState:UIControlStateNormal];g_btnRepS2.backgroundColor=[UIColor colorWithRed:0.15 green:0.15 blue:0.18 alpha:0.95];g_btnRepS2.layer.borderColor=IMGUI_BORDER.CGColor;}
    if(g_replaceSkill3){[g_btnRepS3 setTitle:@"3\xE2\x86\x92\xe5\xa4\xa7" forState:UIControlStateNormal];g_btnRepS3.backgroundColor=IMGUI_BTN_ON;g_btnRepS3.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnRepS3 setTitle:@"3" forState:UIControlStateNormal];g_btnRepS3.backgroundColor=[UIColor colorWithRed:0.15 green:0.15 blue:0.18 alpha:0.95];g_btnRepS3.layer.borderColor=IMGUI_BORDER.CGColor;}
    if(g_replaceSkill4){[g_btnRepS4 setTitle:@"4\xE2\x86\x92\xe5\xa4\xa7" forState:UIControlStateNormal];g_btnRepS4.backgroundColor=IMGUI_BTN_ON;g_btnRepS4.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnRepS4 setTitle:@"4" forState:UIControlStateNormal];g_btnRepS4.backgroundColor=[UIColor colorWithRed:0.15 green:0.15 blue:0.18 alpha:0.95];g_btnRepS4.layer.borderColor=IMGUI_BORDER.CGColor;}
    if(g_replaceSkill5){[g_btnRepS5 setTitle:@"5\xE2\x86\x92\xe5\xa4\xa7" forState:UIControlStateNormal];g_btnRepS5.backgroundColor=IMGUI_BTN_ON;g_btnRepS5.layer.borderColor=IMGUI_GREEN.CGColor;}
    else{[g_btnRepS5 setTitle:@"5" forState:UIControlStateNormal];g_btnRepS5.backgroundColor=[UIColor colorWithRed:0.15 green:0.15 blue:0.18 alpha:0.95];g_btnRepS5.layer.borderColor=IMGUI_BORDER.CGColor;}
    if(g_btnApplySkin){
        if(g_appliedSkinId>0){
            [g_btnApplySkin setTitle:[NSString stringWithFormat:@"皮肤:%d(生效中)",g_appliedSkinId] forState:UIControlStateNormal];
            g_btnApplySkin.backgroundColor=IMGUI_BTN_ON;
            g_btnApplySkin.layer.borderColor=IMGUI_GREEN.CGColor;
        } else if(g_skinIdsLoaded){
            [g_btnApplySkin setTitle:@"应用皮肤" forState:UIControlStateNormal];
            g_btnApplySkin.backgroundColor=[UIColor colorWithRed:0.18 green:0.35 blue:0.55 alpha:0.95];
            g_btnApplySkin.layer.borderColor=IMGUI_ACCENT.CGColor;
        } else {
            [g_btnApplySkin setTitle:@"先扫描皮肤" forState:UIControlStateNormal];
            g_btnApplySkin.backgroundColor=[UIColor colorWithRed:0.35 green:0.14 blue:0.14 alpha:0.95];
            g_btnApplySkin.layer.borderColor=IMGUI_RED.CGColor;
        }
    }
    if(g_btnScanSkin){
        if(g_skinIdsLoaded){[g_btnScanSkin setTitle:[NSString stringWithFormat:@"\xe5\xb7\xb2\xe6\x89\xab\xe6\x8f\x8f:\xe7\x9a\xae\xe8\x82\xa4%d/\xe6\xad\xa6\xe5\x99\xa8%d",g_roleSkinCount,g_weaponSkinCount] forState:UIControlStateNormal];g_btnScanSkin.backgroundColor=[UIColor colorWithRed:0.16 green:0.52 blue:0.28 alpha:0.95];}
        else{[g_btnScanSkin setTitle:@"\xe6\x89\xab\xe6\x8f\x8f\xe7\x9a\xae\xe8\x82\xa4ID" forState:UIControlStateNormal];g_btnScanSkin.backgroundColor=[UIColor colorWithRed:0.18 green:0.35 blue:0.55 alpha:0.95];}
        g_btnScanSkin.layer.borderColor=IMGUI_ACCENT.CGColor;
    }
}

static void layoutPanelCenter(void){if(!g_panel)return;CGRect sc=[UIScreen mainScreen].bounds;CGFloat px=(sc.size.width-g_panelW)/2;g_panel.frame=CGRectMake(px,80,g_panelW,g_panelH);}

static void togglePanel(void){
    g_panelOpen=!g_panelOpen;g_panel.hidden=!g_panelOpen;
    g_resizeHandle.hidden=!g_panelOpen;
    g_resizeHandleTop.hidden=!g_panelOpen;
    if(g_panelOpen){
        layoutPanelCenter();
        CGRect f=g_panel.frame;
        if(g_resizeHandle) g_resizeHandle.frame=CGRectMake(f.origin.x+g_panelW-36,f.origin.y+g_panelH-36,36,36);
        if(g_resizeHandleTop) g_resizeHandleTop.frame=CGRectMake(f.origin.x+g_panelW-36,f.origin.y,36,36);
    }
}

@implementation JYJHActionHandler
+(instancetype)shared{static JYJHActionHandler *s;static dispatch_once_t o;dispatch_once(&o,^{s=[[self alloc]init];});return s;}
-(void)onIgnoreUnlock{
    g_ignoreUnlock=!g_ignoreUnlock;
    if(g_ignoreUnlock&&!g_hUnlock){findIL2CPP();hookOneFunc(g_fUnlock,hUnlock,(void**)&g_oUnlock,&g_hUnlock,"Unlock");}
    refreshBtns();jlog(@"Toggle Unlock: %d",g_ignoreUnlock);
}
-(void)onExSkillNoCD{
    g_exSkillNoCD=!g_exSkillNoCD;
    if(g_exSkillNoCD){findIL2CPP();
        if(!g_hIsReady)hookOneFunc(g_fIsReady,hIsReady,(void**)&g_oIsReady,&g_hIsReady,"IsReady");
        if(!g_hAttackCanUse)hookOneFunc(g_fAttackCanUse,hAttackCanUse,(void**)&g_oAttackCanUse,&g_hAttackCanUse,"AttackCanUse");
    }
    refreshBtns();jlog(@"Toggle NoCD: %d",g_exSkillNoCD);
}
-(void)onGodMode{
    g_godMode=!g_godMode;
    if(g_godMode){findIL2CPP();
        if(!g_hAttackCanUse)hookOneFunc(g_fAttackCanUse,hAttackCanUse,(void**)&g_oAttackCanUse,&g_hAttackCanUse,"AttackCanUse");
        if(!g_hIsReady)hookOneFunc(g_fIsReady,hIsReady,(void**)&g_oIsReady,&g_hIsReady,"IsReady");
        if(!g_hCanBeAttack)hookOneFunc(g_fCanBeAttack,hCanBeAttack,(void**)&g_oCanBeAttack,&g_hCanBeAttack,"CanBeAttack");
        if(!g_hDamage)hookOneFunc(g_fDamage,hDamage,(void**)&g_oDamage,&g_hDamage,"Damage");
    }
    refreshBtns();jlog(@"Toggle God: %d",g_godMode);
}
-(void)onSkillReplace{
    g_skillReplace=!g_skillReplace;
    if(g_skillReplace){findIL2CPP();
        if(!g_hUseSkill)hookOneFunc(g_fUseSkill,hUseSkill,(void**)&g_oUseSkill,&g_hUseSkill,"UseSkill");
        if(!g_hUpdateSkillCD)hookOneFunc(g_fUpdateSkillCD,hUpdateSkillCD,(void**)&g_oUpdateSkillCD,&g_hUpdateSkillCD,"UpdateSkillCD");
        if(!g_hIsReady)hookOneFunc(g_fIsReady,hIsReady,(void**)&g_oIsReady,&g_hIsReady,"IsReady");
        if(!g_hAttackCanUse)hookOneFunc(g_fAttackCanUse,hAttackCanUse,(void**)&g_oAttackCanUse,&g_hAttackCanUse,"AttackCanUse");
        if(!g_hDamage)hookOneFunc(g_fDamage,hDamage,(void**)&g_oDamage,&g_hDamage,"Damage");
    }
    refreshBtns();jlog(@"Toggle SkillReplace: %d",g_skillReplace);
}
// v68: 单技能替换toggle
-(void)onReplaceS1{g_replaceSkill1=!g_replaceSkill1;if(g_replaceSkill1&&!g_skillReplace){g_skillReplace=YES;[self onSkillReplace];}refreshBtns();jlog(@"Replace Skill1->Ult: %d",g_replaceSkill1);}
-(void)onReplaceS2{g_replaceSkill2=!g_replaceSkill2;if(g_replaceSkill2&&!g_skillReplace){g_skillReplace=YES;[self onSkillReplace];}refreshBtns();jlog(@"Replace Skill2->Ult: %d",g_replaceSkill2);}
-(void)onReplaceS3{g_replaceSkill3=!g_replaceSkill3;if(g_replaceSkill3&&!g_skillReplace){g_skillReplace=YES;[self onSkillReplace];}refreshBtns();jlog(@"Replace Skill3->Ult: %d",g_replaceSkill3);}
-(void)onReplaceS4{g_replaceSkill4=!g_replaceSkill4;if(g_replaceSkill4&&!g_skillReplace){g_skillReplace=YES;[self onSkillReplace];}refreshBtns();jlog(@"Replace Skill4->Ult: %d",g_replaceSkill4);}
-(void)onReplaceS5{g_replaceSkill5=!g_replaceSkill5;if(g_replaceSkill5&&!g_skillReplace){g_skillReplace=YES;[self onSkillReplace];}refreshBtns();jlog(@"Replace Skill5->Ult: %d",g_replaceSkill5);}
// v69: 移动加速slider
-(void)speedSliderChanged:(UISlider*)s{
    g_speedMul=s.value;
    if(g_speedMul>1.0f && !g_hMoveStep) {
        findIL2CPP();
        if(!g_hMoveStep) hookOneFunc(g_fMoveStep,hMoveStep,(void**)&g_oMoveStep,&g_hMoveStep,"MoveStep");
    }
    g_speedLabel.text=[NSString stringWithFormat:@"移动速度: %.1fx",g_speedMul];
    jlog(@"SpeedMul: %.1f",g_speedMul);
}
-(void)onFullScreen{
    g_fullScreen=!g_fullScreen;
    if(g_fullScreen){findIL2CPP();
        if(!g_hIntersects)hookOneFunc(g_fIntersects,hIntersects,(void**)&g_oIntersects,&g_hIntersects,"Intersects");
        if(!g_hCheckHit)hookOneFunc(g_fCheckHit,hCheckHit,(void**)&g_oCheckHit,&g_hCheckHit,"CheckHit(Z)");
        if(!g_hDamage)hookOneFunc(g_fDamage,hDamage,(void**)&g_oDamage,&g_hDamage,"Damage");
        if(!g_hHitSystemUpdate)hookOneFunc(g_fHitSystemUpdate,hHitSystemUpdate,(void**)&g_oHitSystemUpdate,&g_hHitSystemUpdate,"HitSystem.Update");
        g_enemyCount=0;
        jlog(@"FullScreen ON");
    }else{jlog(@"FullScreen OFF");}
    refreshBtns();
}
-(void)onDumpSkinIds{
    if(!g_classUnityGameEntry&&!g_classHotfixGameEntry){jlog(@"DumpSkin: classes not found, running findIL2CPP...");findIL2CPP();}
    if(g_skinIdsLoaded){jlog(@"DumpSkin: already scanned, role=%d weapon=%d",g_roleSkinCount,g_weaponSkinCount);refreshBtns();return;}
    jlog(@"DumpSkin: starting (pure memory read)...");
    scanSkinIds();
    refreshBtns();
}
-(void)sliderChanged:(UISlider*)s{g_damageLimit=(int)s.value;g_sliderLabel.text=[NSString stringWithFormat:@"\xe4\xbc\xa4\xe5\xae\xb3\xe4\xb8\x8a\xe9\x99\x90: %d",g_damageLimit];}
-(void)skinSliderChanged:(UISlider*)s{
    int idx=(int)s.value;
    // v68: clamp to valid range
    if(g_skinIdsLoaded){
        if(idx<0) idx=0;
        if(idx>=g_roleSkinCount) idx=g_roleSkinCount-1;
        g_skinId=g_roleSkinIds[idx];
    } else {
        g_skinId=idx;
    }
    g_skinLabel.text=[NSString stringWithFormat:@"\xe7\x9a\xae\xe8\x82\xa4" "ID: %d",g_skinId];
}
-(void)weaponSliderChanged:(UISlider*)s{
    int idx=(int)s.value;
    // v68: clamp to valid range
    if(g_skinIdsLoaded){
        if(idx<0) idx=0;
        if(idx>=g_weaponSkinCount) idx=g_weaponSkinCount-1;
        g_weaponId=g_weaponSkinIds[idx];
    } else {
        g_weaponId=idx;
    }
    g_weaponLabel.text=[NSString stringWithFormat:@"\xe6\xad\xa6\xe5\x99\xa8" "ID: %d",g_weaponId];
}
-(void)onApplySkin{
    // v72: 恢复get_SkinId Hook方式(只改返回值,不改帧同步内存)
    // v68用此方法成功显示皮肤; v69因写backing field卡死
    // v72只hook返回值, 不会卡死
    if(!g_skinIdsLoaded){jlog(@"ApplySkin: scan skins first");return;}
    if(!g_fGetSkinId){jlog(@"ApplySkin: get_SkinId not found");return;}
    
    // Hook get_SkinId(如果还没hook)
    if(!g_hGetSkinId) {
        hookOneFunc(g_fGetSkinId,hGetSkinId,(void**)&g_oGetSkinId,&g_hGetSkinId,"get_SkinId");
    }
    g_appliedSkinId=g_skinId; g_appliedWeaponId=g_weaponId;
    jlog(@"ApplySkin: skin=%d weapon=%d (get_SkinId hook active)",g_skinId,g_weaponId);
}
@end

@interface JYJHResizeHandle : UIView { CGPoint _ts; }
@end
@implementation JYJHResizeHandle
-(instancetype)init{
    self=[super initWithFrame:CGRectMake(0,0,36,36)];
    if(self){
    self.backgroundColor=[UIColor clearColor];self.layer.zPosition=9999;
    UIView *t=[[UIView alloc]initWithFrame:CGRectMake(0,0,36,36)];t.backgroundColor=[UIColor colorWithRed:0.3 green:0.3 blue:0.4 alpha:0.85];t.layer.cornerRadius=6;[self addSubview:t];
    UILabel *l=[[UILabel alloc]initWithFrame:CGRectMake(0,0,36,36)];l.text=@"\xe2\x87\x98";l.textColor=[UIColor whiteColor];l.font=[UIFont systemFontOfSize:18];l.textAlignment=NSTextAlignmentCenter;[self addSubview:l];
    }return self;
}
-(BOOL)pointInside:(CGPoint)p withEvent:(UIEvent*)e{return CGRectContainsPoint(CGRectInset(self.bounds,-6,-6),p);}
-(void)touchesBegan:(NSSet*)t withEvent:(UIEvent*)e{_ts=[[t anyObject]locationInView:g_panel.superview];}
-(void)touchesMoved:(NSSet*)t withEvent:(UIEvent*)e{
    CGPoint c=[[t anyObject]locationInView:g_panel.superview];
    CGFloat nw=MAX(200,c.x-g_panel.frame.origin.x);CGFloat nh=MAX(300,c.y-g_panel.frame.origin.y);
    g_panelW=nw;g_panelH=nh;g_panel.frame=CGRectMake(g_panel.frame.origin.x,g_panel.frame.origin.y,nw,nh);
    if(g_scrollView){g_scrollView.frame=CGRectMake(0,32,nw,nh-32);g_scrollView.contentSize=CGSizeMake(nw,g_scrollView.contentSize.height);}
    if(g_resizeHandle) g_resizeHandle.frame=CGRectMake(g_panel.frame.origin.x+nw-36,g_panel.frame.origin.y+nh-36,36,36);
    if(g_resizeHandleTop) g_resizeHandleTop.frame=CGRectMake(g_panel.frame.origin.x+nw-36,g_panel.frame.origin.y,36,36);
}
@end

@interface JYJHTitleDragView : UIView { CGPoint _ts; }
@end
@implementation JYJHTitleDragView
-(void)touchesBegan:(NSSet*)t withEvent:(UIEvent*)e{_ts=[[t anyObject]locationInView:g_panel.superview];}
-(void)touchesMoved:(NSSet*)t withEvent:(UIEvent*)e{
    CGPoint c=[[t anyObject]locationInView:g_panel.superview];CGFloat dx=c.x-_ts.x,dy=c.y-_ts.y;
    CGRect f=g_panel.frame;CGRect sc=[UIScreen mainScreen].bounds;
    f.origin.x=MAX(-f.size.width+40,MIN(sc.size.width-40,f.origin.x+dx));f.origin.y=MAX(-20,MIN(sc.size.height-60,f.origin.y+dy));
    g_panel.frame=f;
    if(g_resizeHandle) g_resizeHandle.frame=CGRectMake(f.origin.x+g_panelW-36,f.origin.y+g_panelH-36,36,36);
    if(g_resizeHandleTop) g_resizeHandleTop.frame=CGRectMake(f.origin.x+g_panelW-36,f.origin.y,36,36);
    _ts=c;
}
@end

@interface JYJHBallView : UIView { CGPoint _ts; BOOL _drag; }
@end
@implementation JYJHBallView
-(instancetype)init{
    self=[super initWithFrame:CGRectMake([UIScreen mainScreen].bounds.size.width-46,150,40,40)];
    if(self){
    self.backgroundColor=IMGUI_BALL_BG;self.layer.cornerRadius=20;self.layer.borderWidth=2;self.layer.borderColor=IMGUI_ACCENT.CGColor;self.userInteractionEnabled=YES;
    UILabel*l=[[UILabel alloc]initWithFrame:CGRectMake(0,0,40,40)];l.text=@"\xe5\x89\x91";l.textColor=[UIColor whiteColor];l.font=[UIFont boldSystemFontOfSize:18];l.textAlignment=NSTextAlignmentCenter;[self addSubview:l];
    }return self;
}
-(BOOL)pointInside:(CGPoint)p withEvent:(UIEvent*)e{return CGRectContainsPoint(CGRectInset(self.bounds,-8,-8),p);}
-(void)touchesBegan:(NSSet*)t withEvent:(UIEvent*)e{_ts=[[t anyObject]locationInView:self.superview];_drag=NO;}
-(void)touchesMoved:(NSSet*)t withEvent:(UIEvent*)e{CGPoint c=[[t anyObject]locationInView:self.superview];CGFloat dx=c.x-_ts.x,dy=c.y-_ts.y;if(fabs(dx)>5||fabs(dy)>5){_drag=YES;CGRect f=self.frame;CGRect sc=[UIScreen mainScreen].bounds;f.origin.x=MAX(0,MIN(sc.size.width-f.size.width,f.origin.x+dx));f.origin.y=MAX(50,MIN(sc.size.height-f.size.height-50,f.origin.y+dy));self.frame=f;_ts=c;}}
-(void)touchesEnded:(NSSet*)t withEvent:(UIEvent*)e{if(!_drag)togglePanel();_drag=NO;}
-(void)touchesCancelled:(NSSet*)t withEvent:(UIEvent*)e{_drag=NO;}
@end

static UIWindow *getKeyWindow(void){for(UIWindow *w in [UIApplication sharedApplication].windows)if(!w.isHidden)return w;return nil;}

static void setupUI(void){
    UIWindow *win=getKeyWindow();
    if(!win){dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{setupUI();});return;}
    JYJHBallView *ball=[[JYJHBallView alloc]init];[win addSubview:ball];
    UIView *outer=[[UIView alloc]initWithFrame:CGRectMake(0,0,g_panelW,g_panelH)];outer.backgroundColor=IMGUI_BG;outer.layer.cornerRadius=10;outer.layer.borderWidth=1;outer.layer.borderColor=IMGUI_BORDER.CGColor;outer.hidden=YES;g_panel=outer;[win addSubview:outer];
    layoutPanelCenter();
    JYJHTitleDragView *tb=[[JYJHTitleDragView alloc]initWithFrame:CGRectMake(0,0,g_panelW,32)];tb.backgroundColor=IMGUI_TITLE_BG;[outer addSubview:tb];g_titleBar=tb;
    UILabel *tl=[[UILabel alloc]initWithFrame:CGRectMake(10,6,g_panelW-20,20)];tl.text=@"\xe5\x89\x91\xe5\xbd\xb1\xe6\xb1\x9f\xe6\xb9\x96 v73";tl.textColor=IMGUI_ACCENT;tl.font=[UIFont boldSystemFontOfSize:15];tl.textAlignment=NSTextAlignmentCenter;[tb addSubview:tl];
    UIScrollView *sv=[[UIScrollView alloc]initWithFrame:CGRectMake(0,32,g_panelW,g_panelH-32)];
    sv.showsVerticalScrollIndicator=YES;sv.delaysContentTouches=NO;sv.canCancelContentTouches=YES;sv.scrollEnabled=YES;sv.userInteractionEnabled=YES;
    [outer addSubview:sv]; g_scrollView=sv;
    CGFloat bx=12,bw=g_panelW-24,bh=24,by0=4,bdy=28;
    // v68: 技能替换区域需要2行(主开关+5个小按钮)
    CGFloat contentH=by0+bdy*6+60+220; // v69: 增加速度slider空间
    sv.contentSize=CGSizeMake(g_panelW,contentH);
    g_btnIgnoreUnlock=mkBtn(CGRectMake(bx,by0,bw,bh),@selector(onIgnoreUnlock));[sv addSubview:g_btnIgnoreUnlock];
    g_btnExSkillNoCD=mkBtn(CGRectMake(bx,by0+bdy,bw,bh),@selector(onExSkillNoCD));[sv addSubview:g_btnExSkillNoCD];
    g_btnGodMode=mkBtn(CGRectMake(bx,by0+bdy*2,bw,bh),@selector(onGodMode));[sv addSubview:g_btnGodMode];
    g_btnFullScreen=mkBtn(CGRectMake(bx,by0+bdy*3,bw,bh),@selector(onFullScreen));[sv addSubview:g_btnFullScreen];
    g_btnSkillReplace=mkBtn(CGRectMake(bx,by0+bdy*4,bw,bh),@selector(onSkillReplace));[sv addSubview:g_btnSkillReplace];
    // v68: 5个小按钮选择哪个技能替换成大招, 一行排列
    CGFloat repY=by0+bdy*5;
    CGFloat sbw=(bw-4*5)/5; // 5个按钮等宽, 间距4
    g_btnRepS1=mkBtn(CGRectMake(bx,repY,sbw,bh),@selector(onReplaceS1));[sv addSubview:g_btnRepS1];
    g_btnRepS2=mkBtn(CGRectMake(bx+sbw+4,repY,sbw,bh),@selector(onReplaceS2));[sv addSubview:g_btnRepS2];
    g_btnRepS3=mkBtn(CGRectMake(bx+(sbw+4)*2,repY,sbw,bh),@selector(onReplaceS3));[sv addSubview:g_btnRepS3];
    g_btnRepS4=mkBtn(CGRectMake(bx+(sbw+4)*3,repY,sbw,bh),@selector(onReplaceS4));[sv addSubview:g_btnRepS4];
    g_btnRepS5=mkBtn(CGRectMake(bx+(sbw+4)*4,repY,sbw,bh),@selector(onReplaceS5));[sv addSubview:g_btnRepS5];
    CGFloat s1Y=by0+bdy*6;UIView *s1=[[UIView alloc]initWithFrame:CGRectMake(bx,s1Y,bw,1)];s1.backgroundColor=IMGUI_BORDER;[sv addSubview:s1];
    CGFloat sy=s1Y+8;
    g_sliderLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,sy,bw,18)];g_sliderLabel.text=[NSString stringWithFormat:@"\xe4\xbc\xa4\xe5\xae\xb3\xe4\xb8\x8a\xe9\x99\x90: %d",g_damageLimit];g_sliderLabel.textColor=IMGUI_DIMTEXT;g_sliderLabel.font=[UIFont systemFontOfSize:12];[sv addSubview:g_sliderLabel];
    g_slider=[[UISlider alloc]initWithFrame:CGRectMake(bx,sy+20,bw,28)];g_slider.minimumValue=1;g_slider.maximumValue=5000;g_slider.value=g_damageLimit;[g_slider addTarget:[JYJHActionHandler shared] action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_slider];
    CGFloat s2Y=sy+52;UIView *s2=[[UIView alloc]initWithFrame:CGRectMake(bx,s2Y,bw,1)];s2.backgroundColor=IMGUI_BORDER;[sv addSubview:s2];
    CGFloat ssy=s2Y+6;
    // v67: 皮肤slider范围 - 扫描后用索引, 未扫描用原始值
    int skinMax = g_skinIdsLoaded ? g_roleSkinCount-1 : 2000;
    int weaponMax = g_skinIdsLoaded ? g_weaponSkinCount-1 : 2000;
    UILabel *secT=[[UILabel alloc]initWithFrame:CGRectMake(bx,ssy,bw,18)];
    if(g_skinIdsLoaded){
        secT.text=[NSString stringWithFormat:@"\xe7\x9a\xae\xe8\x82\xa4/\xe6\xad\xa6\xe5\x99\xa8" "(\xe6\xbb\x91\xe5\x8a\xa8\xe9\x80\x89\xe6\x8b\xa9 \xe7\x9a\xae\xe8\x82\xa4%d/\xe6\xad\xa6\xe5\x99\xa8%d)",g_roleSkinCount,g_weaponSkinCount];
    } else {
        secT.text=@"\xe7\x9a\xae\xe8\x82\xa4/\xe6\xad\xa6\xe5\x99\xa8" "(\xe5\x85\x88\xe7\x82\xb9\xe6\x89\xab\xe6\x8f\x8f)";
    }
    secT.textColor=IMGUI_ACCENT;secT.font=[UIFont boldSystemFontOfSize:11];[sv addSubview:secT];
    g_skinLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,ssy+20,bw,18)];g_skinLabel.text=[NSString stringWithFormat:@"\xe7\x9a\xae\xe8\x82\xa4" "ID: %d",g_skinId];g_skinLabel.textColor=IMGUI_DIMTEXT;g_skinLabel.font=[UIFont systemFontOfSize:12];[sv addSubview:g_skinLabel];
    g_skinSlider=[[UISlider alloc]initWithFrame:CGRectMake(bx,ssy+38,bw,28)];g_skinSlider.minimumValue=0;g_skinSlider.maximumValue=skinMax;g_skinSlider.value=0;[g_skinSlider addTarget:[JYJHActionHandler shared] action:@selector(skinSliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_skinSlider];
    g_weaponLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,ssy+68,bw,18)];g_weaponLabel.text=[NSString stringWithFormat:@"\xe6\xad\xa6\xe5\x99\xa8" "ID: %d",g_weaponId];g_weaponLabel.textColor=IMGUI_DIMTEXT;g_weaponLabel.font=[UIFont systemFontOfSize:12];[sv addSubview:g_weaponLabel];
    g_weaponSlider=[[UISlider alloc]initWithFrame:CGRectMake(bx,ssy+86,bw,28)];g_weaponSlider.minimumValue=0;g_weaponSlider.maximumValue=weaponMax;g_weaponSlider.value=0;[g_weaponSlider addTarget:[JYJHActionHandler shared] action:@selector(weaponSliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_weaponSlider];
    g_btnApplySkin=mkBtn(CGRectMake(bx,ssy+118,bw,bh),@selector(onApplySkin));[sv addSubview:g_btnApplySkin];
    g_btnScanSkin=mkBtn(CGRectMake(bx,ssy+146,bw,bh),@selector(onDumpSkinIds));[sv addSubview:g_btnScanSkin];
    // v69: 移动速度slider
    CGFloat s3Y=ssy+174;UIView *s3=[[UIView alloc]initWithFrame:CGRectMake(bx,s3Y,bw,1)];s3.backgroundColor=IMGUI_BORDER;[sv addSubview:s3];
    CGFloat spy=s3Y+4;
    g_speedLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,spy,bw,18)];g_speedLabel.text=[NSString stringWithFormat:@"\xe7\xa7\xbb\xe5\x8a\xa8\xe9\x80\x9f\xe5\xba\xa6: %.1fx",g_speedMul];g_speedLabel.textColor=IMGUI_ACCENT;g_speedLabel.font=[UIFont boldSystemFontOfSize:12];[sv addSubview:g_speedLabel];
    g_speedSlider=[[UISlider alloc]initWithFrame:CGRectMake(bx,spy+20,bw,28)];g_speedSlider.minimumValue=1.0;g_speedSlider.maximumValue=5.0;g_speedSlider.value=g_speedMul;[g_speedSlider addTarget:[JYJHActionHandler shared] action:@selector(speedSliderChanged:) forControlEvents:UIControlEventValueChanged];[sv addSubview:g_speedSlider];
    g_resizeHandle=[[JYJHResizeHandle alloc]init];
    CGRect panelFrame=g_panel.frame;
    g_resizeHandle.frame=CGRectMake(panelFrame.origin.x+g_panelW-36,panelFrame.origin.y+g_panelH-36,36,36);g_resizeHandle.hidden=YES;[win addSubview:g_resizeHandle];
    g_resizeHandleTop=[[JYJHResizeHandle alloc]init];
    g_resizeHandleTop.frame=CGRectMake(panelFrame.origin.x+g_panelW-36,panelFrame.origin.y,36,36);g_resizeHandleTop.hidden=YES;[win addSubview:g_resizeHandleTop];
    refreshBtns();
}

__attribute__((constructor))
static void initialize(void){
    static BOOL loaded=NO; if(loaded)return; loaded=YES;
    jlog(@"========== JYJH v73 ==========");
    jlog(@"iOS %@",[[UIDevice currentDevice] systemVersion]);
    // v73: 延迟安装反检测hook - constructor阶段dyld还在初始化,
    // 此时DobbyHook dyld函数会导致dyld内部调用被劫持而崩溃(SIGBUS/SIGSEGV)
    // 必须等dyld完成所有初始化后再hook
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"1s delay: installing anti-detect hooks");
        installAntiDetectHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(4.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            jlog(@"5s delay done"); applyAllHooks();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{setupUI();});
        });
    });
}
