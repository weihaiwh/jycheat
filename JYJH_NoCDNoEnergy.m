/**
 * 剑影江湖 (com.jyjh.whwb) v1.10.1 - 无CD无能量技能插件
 * v3.0: 悬浮菜单 + 内存补丁
 * 
 * 新偏移 (v1.10.1):
 *   CheckSkillAttackCanUse: 0x30741B8
 *   CheckSkillIsReady:      0x3074B54
 *
 * 功能:
 *   [开关] 无CD - patch CheckSkillAttackCanUse -> return true
 *   [开关] 无能量 - patch CheckSkillIsReady -> return true
 * 
 * 悬浮菜单: 点击可切换开关状态
 */

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

/* extern declarations */
extern void NSLog(NSString *format, ...) __attribute__((format(NSString, 1, 2)));
extern void sys_icache_invalidate(void *start, size_t len);

#define LOG(fmt, args...) NSLog(@"[JYJH] " fmt, ##args)

/* ====== 偏移 (v1.10.1) ====== */
static const uint64_t OFF_CheckSkillAttackCanUse = 0x30741B8;
static const uint64_t OFF_CheckSkillIsReady       = 0x3074B54;

/* arm64: mov w0,#1; ret */
static const uint32_t ARM64_MOV_W0_1 = 0x52800020;
static const uint32_t ARM64_RET      = 0xD65F03C0;

/* ====== 全局状态 ====== */
static uint64_t g_base = 0;
static BOOL g_noCD = YES;
static BOOL g_noEnergy = YES;
static BOOL g_patchesApplied = NO;

/* 保存原始指令用于恢复 */
static uint32_t g_orig_checkCanUse[2] = {0, 0};
static uint32_t g_orig_checkIsReady[2] = {0, 0};

/* ====== 内存补丁 ====== */
static kern_return_t patchMemory(void *addr, const void *newData, const void *origData, size_t size) {
    vm_address_t page = (vm_address_t)addr & ~(vm_page_size - 1);
    
    kern_return_t kr = vm_protect(mach_task_self(), page, vm_page_size,
                                   false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        kr = vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_ALL);
        if (kr != KERN_SUCCESS) return kr;
    }
    
    /* 如果有原始数据，先保存 */
    if (origData) {
        memcpy((void *)origData, addr, size);
    }
    
    memcpy(addr, newData, size);
    sys_icache_invalidate(addr, size);
    
    vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ | VM_PROT_EXECUTE);
    return KERN_SUCCESS;
}

/* ====== 查找模块基址 ====== */
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

/* ====== 应用/恢复补丁 ====== */
static void applyPatches(void) {
    if (g_patchesApplied && g_base) {
        /* 已经找到模块，直接patch/恢复 */
        uint32_t patch[] = { ARM64_MOV_W0_1, ARM64_RET };
        
        void *addr1 = (void *)(g_base + OFF_CheckSkillAttackCanUse);
        if (g_noCD) {
            patchMemory(addr1, patch, NULL, sizeof(patch));
        } else if (g_orig_checkCanUse[0] != 0) {
            patchMemory(addr1, g_orig_checkCanUse, NULL, sizeof(patch));
        }
        
        void *addr2 = (void *)(g_base + OFF_CheckSkillIsReady);
        if (g_noEnergy) {
            patchMemory(addr2, patch, NULL, sizeof(patch));
        } else if (g_orig_checkIsReady[0] != 0) {
            patchMemory(addr2, g_orig_checkIsReady, NULL, sizeof(patch));
        }
        return;
    }
    
    g_base = findModuleBase("FrameSync.code.dll");
    if (!g_base) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ applyPatches(); });
        return;
    }
    
    /* 保存原始指令 */
    uint32_t patch[] = { ARM64_MOV_W0_1, ARM64_RET };
    
    void *addr1 = (void *)(g_base + OFF_CheckSkillAttackCanUse);
    void *addr2 = (void *)(g_base + OFF_CheckSkillIsReady);
    
    /* 保存原始代码 */
    memcpy(g_orig_checkCanUse, addr1, 8);
    memcpy(g_orig_checkIsReady, addr2, 8);
    
    if (g_noCD) {
        patchMemory(addr1, patch, NULL, sizeof(patch));
    }
    if (g_noEnergy) {
        patchMemory(addr2, patch, NULL, sizeof(patch));
    }
    
    g_patchesApplied = YES;
}

/* ====== 悬浮菜单 ====== */

@interface JYJHMenuView : UIView
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UIView *menuPanel;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *noCDButton;
@property (nonatomic, strong) UIButton *noEnergyButton;
@property (nonatomic) BOOL menuVisible;
@property (nonatomic) CGPoint lastTouchPoint;
@end

@implementation JYJHMenuView

- (instancetype)init {
    CGRect screen = [UIScreen mainScreen].bounds;
    self = [super initWithFrame:CGRectMake(screen.size.width - 50, 200, 44, 44)];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.85];
        self.layer.cornerRadius = 22;
        self.clipsToBounds = YES;
        
        /* 悬浮按钮 */
        _toggleButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _toggleButton.frame = CGRectMake(0, 0, 44, 44);
        [_toggleButton setTitle:@"剑" forState:UIControlStateNormal];
        _toggleButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        [_toggleButton addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_toggleButton];
        
        /* 菜单面板 */
        CGFloat panelW = 180;
        CGFloat panelH = 140;
        _menuPanel = [[UIView alloc] initWithFrame:CGRectMake(-panelW + 44, 0, panelW, panelH)];
        _menuPanel.backgroundColor = [UIColor colorWithRed:0.15 green:0.15 blue:0.2 alpha:0.95];
        _menuPanel.layer.cornerRadius = 12;
        _menuPanel.clipsToBounds = YES;
        _menuPanel.hidden = YES;
        [self addSubview:_menuPanel];
        
        /* 标题 */
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 8, panelW - 20, 24)];
        _titleLabel.text = @"剑影江湖 v1.10.1";
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.font = [UIFont boldSystemFontOfSize:14];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        [_menuPanel addSubview:_titleLabel];
        
        /* 无CD按钮 */
        _noCDButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _noCDButton.frame = CGRectMake(10, 40, panelW - 20, 36);
        _noCDButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.2 alpha:0.9];
        _noCDButton.layer.cornerRadius = 8;
        [_noCDButton setTitle:@"✅ 无CD: 开" forState:UIControlStateNormal];
        _noCDButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [_noCDButton addTarget:self action:@selector(toggleNoCD) forControlEvents:UIControlEventTouchUpInside];
        [_menuPanel addSubview:_noCDButton];
        
        /* 无能量按钮 */
        _noEnergyButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _noEnergyButton.frame = CGRectMake(10, 84, panelW - 20, 36);
        _noEnergyButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.2 alpha:0.9];
        _noEnergyButton.layer.cornerRadius = 8;
        [_noEnergyButton setTitle:@"✅ 无能量: 开" forState:UIControlStateNormal];
        _noEnergyButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [_noEnergyButton addTarget:self action:@selector(toggleNoEnergy) forControlEvents:UIControlEventTouchUpInside];
        [_menuPanel addSubview:_noEnergyButton];
        
        _menuVisible = NO;
    }
    return self;
}

- (void)toggleMenu {
    _menuVisible = !_menuVisible;
    _menuPanel.hidden = !_menuVisible;
}

- (void)toggleNoCD {
    g_noCD = !g_noCD;
    if (g_noCD) {
        [_noCDButton setTitle:@"✅ 无CD: 开" forState:UIControlStateNormal];
        _noCDButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.2 alpha:0.9];
    } else {
        [_noCDButton setTitle:@"❌ 无CD: 关" forState:UIControlStateNormal];
        _noCDButton.backgroundColor = [UIColor colorWithRed:0.6 green:0.2 blue:0.2 alpha:0.9];
    }
    applyPatches();
}

- (void)toggleNoEnergy {
    g_noEnergy = !g_noEnergy;
    if (g_noEnergy) {
        [_noEnergyButton setTitle:@"✅ 无能量: 开" forState:UIControlStateNormal];
        _noEnergyButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.2 alpha:0.9];
    } else {
        [_noEnergyButton setTitle:@"❌ 无能量: 关" forState:UIControlStateNormal];
        _noEnergyButton.backgroundColor = [UIColor colorWithRed:0.6 green:0.2 blue:0.2 alpha:0.9];
    }
    applyPatches();
}

/* 拖拽支持 */
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *touch = [touches anyObject];
    _lastTouchPoint = [touch locationInView:self];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *touch = [touches anyObject];
    CGPoint current = [touch locationInView:self];
    CGPoint delta = CGPointMake(current.x - _lastTouchPoint.x, current.y - _lastTouchPoint.y);
    CGPoint newCenter = CGPointMake(self.center.x + delta.x, self.center.y + delta.y);
    
    CGRect screen = [UIScreen mainScreen].bounds;
    newCenter.x = MAX(22, MIN(screen.size.width - 22, newCenter.x));
    newCenter.y = MAX(22, MIN(screen.size.height - 22, newCenter.y));
    
    self.center = newCenter;
    _lastTouchPoint = current;
}

@end

/* ====== 显示菜单 ====== */
static void showMenu(void) {
    /* 等待UI准备好 */
    UIViewController *rootVC = nil;
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window.isKeyWindow) {
            rootVC = window.rootViewController;
            break;
        }
    }
    
    if (!rootVC) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ showMenu(); });
        return;
    }
    
    /* 尝试找到最顶层的VC */
    while (rootVC.presentedViewController) {
        rootVC = rootVC.presentedViewController;
    }
    
    JYJHMenuView *menu = [[JYJHMenuView alloc] init];
    [rootVC.view addSubview:menu];
}

/* ====== 入口 ====== */
__attribute__((constructor))
static void initialize(void) {
    LOG(@"JYJH v3.0 loaded (v1.10.1 offsets)");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        applyPatches();
        showMenu();
    });
}