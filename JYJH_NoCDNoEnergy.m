/**
 * 剑影江湖 (com.jyjh.whwb) v1.10.1 - 无CD无能量技能插件
 * v3.1: 修复悬浮菜单显示问题
 */

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <UIKit/UIKit.h>

extern void NSLog(NSString *format, ...) __attribute__((format(NSString, 1, 2)));
extern void sys_icache_invalidate(void *start, size_t len);

#define LOG(fmt, args...) NSLog(@"[JYJH] " fmt, ##args)

/* 偏移 (v1.10.1) */
static const uint64_t OFF_CheckSkillAttackCanUse = 0x30741B8;
static const uint64_t OFF_CheckSkillIsReady       = 0x3074B54;

static const uint32_t ARM64_MOV_W0_1 = 0x52800020;
static const uint32_t ARM64_RET      = 0xD65F03C0;

static uint64_t g_base = 0;
static BOOL g_noCD = YES;
static BOOL g_noEnergy = YES;
static BOOL g_patchesApplied = NO;
static uint32_t g_orig_checkCanUse[2] = {0, 0};
static uint32_t g_orig_checkIsReady[2] = {0, 0};

/* ====== 内存补丁 ====== */
static kern_return_t patchMemory(void *addr, const void *data, size_t size) {
    vm_address_t page = (vm_address_t)addr & ~(vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), page, vm_page_size,
                                   false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        kr = vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_ALL);
        if (kr != KERN_SUCCESS) return kr;
    }
    memcpy(addr, data, size);
    sys_icache_invalidate(addr, size);
    vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ | VM_PROT_EXECUTE);
    return KERN_SUCCESS;
}

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

static void applyOrRestorePatches(void) {
    if (!g_base) {
        g_base = findModuleBase("FrameSync.code.dll");
        if (!g_base) return;
        memcpy(g_orig_checkCanUse, (void *)(g_base + OFF_CheckSkillAttackCanUse), 8);
        memcpy(g_orig_checkIsReady, (void *)(g_base + OFF_CheckSkillIsReady), 8);
        g_patchesApplied = YES;
    }
    
    uint32_t patch[] = { ARM64_MOV_W0_1, ARM64_RET };
    
    if (g_noCD) {
        patchMemory((void *)(g_base + OFF_CheckSkillAttackCanUse), patch, sizeof(patch));
    } else if (g_orig_checkCanUse[0]) {
        patchMemory((void *)(g_base + OFF_CheckSkillAttackCanUse), g_orig_checkCanUse, sizeof(patch));
    }
    
    if (g_noEnergy) {
        patchMemory((void *)(g_base + OFF_CheckSkillIsReady), patch, sizeof(patch));
    } else if (g_orig_checkIsReady[0]) {
        patchMemory((void *)(g_base + OFF_CheckSkillIsReady), g_orig_checkIsReady, sizeof(patch));
    }
}

/* ====== 悬浮菜单 - 使用独立Window ====== */

@interface JYJHMenuWindow : UIWindow
@property (nonatomic, strong) UIButton *toggleBtn;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIButton *noCDBtn;
@property (nonatomic, strong) UIButton *noEnergyBtn;
@property (nonatomic) BOOL expanded;
@property (nonatomic) CGPoint dragStart;
@end

@implementation JYJHMenuWindow

- (instancetype)init {
    CGRect screen = [UIScreen mainScreen].bounds;
    /* 整个window覆盖屏幕，但背景透明，只接收悬浮球和菜单的触摸 */
    self = [super initWithFrame:screen];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.windowLevel = UIWindowLevelAlert + 100;
        self.userInteractionEnabled = NO; /* 默认不拦截触摸 */
        
        /* 悬浮球 */
        CGFloat btnSize = 44;
        CGFloat btnX = screen.size.width - btnSize - 10;
        CGFloat btnY = 200;
        _toggleBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        _toggleBtn.frame = CGRectMake(btnX, btnY, btnSize, btnSize);
        _toggleBtn.backgroundColor = [UIColor colorWithRed:0.1 green:0.5 blue:0.95 alpha:0.9];
        _toggleBtn.layer.cornerRadius = btnSize / 2;
        _toggleBtn.clipsToBounds = YES;
        [_toggleBtn setTitle:@"剑" forState:UIControlStateNormal];
        _toggleBtn.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        [_toggleBtn addTarget:self action:@selector(onToggle) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_toggleBtn];
        
        /* 菜单面板 - 相对悬浮球定位 */
        CGFloat panelW = 180, panelH = 150;
        _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, panelW, panelH)];
        _panel.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.18 alpha:0.97];
        _panel.layer.cornerRadius = 14;
        _panel.clipsToBounds = YES;
        _panel.hidden = YES;
        [self addSubview:_panel];
        
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 10, panelW, 22)];
        title.text = @"剑影江湖 v1.10.1";
        title.textColor = [UIColor whiteColor];
        title.font = [UIFont boldSystemFontOfSize:14];
        title.textAlignment = NSTextAlignmentCenter;
        [_panel addSubview:title];
        
        _noCDBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        _noCDBtn.frame = CGRectMake(12, 42, panelW - 24, 40);
        _noCDBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95];
        _noCDBtn.layer.cornerRadius = 10;
        [_noCDBtn setTitle:@"✅ 无CD: 开" forState:UIControlStateNormal];
        _noCDBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        [_noCDBtn addTarget:self action:@selector(onNoCD) forControlEvents:UIControlEventTouchUpInside];
        [_panel addSubview:_noCDBtn];
        
        _noEnergyBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        _noEnergyBtn.frame = CGRectMake(12, 92, panelW - 24, 40);
        _noEnergyBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95];
        _noEnergyBtn.layer.cornerRadius = 10;
        [_noEnergyBtn setTitle:@"✅ 无能量: 开" forState:UIControlStateNormal];
        _noEnergyBtn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
        [_noEnergyBtn addTarget:self action:@selector(onNoEnergy) forControlEvents:UIControlEventTouchUpInside];
        [_panel addSubview:_noEnergyBtn];
        
        _expanded = NO;
    }
    return self;
}

- (void)layoutPanel {
    CGRect btnFrame = _toggleBtn.frame;
    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat panelW = 180, panelH = 150;
    
    /* 面板在悬浮球左侧，如果空间不够就放右侧 */
    CGFloat panelX = btnFrame.origin.x - panelW - 6;
    if (panelX < 4) {
        panelX = btnFrame.origin.x + btnFrame.size.width + 6;
    }
    CGFloat panelY = btnFrame.origin.y - 20;
    if (panelY + panelH > screen.size.height - 4) {
        panelY = screen.size.height - panelH - 4;
    }
    if (panelY < 4) panelY = 4;
    
    _panel.frame = CGRectMake(panelX, panelY, panelW, panelH);
}

- (void)onToggle {
    _expanded = !_expanded;
    _panel.hidden = !_expanded;
    self.userInteractionEnabled = _expanded; /* 展开时拦截触摸 */
    
    if (_expanded) {
        [self layoutPanel];
    }
}

- (void)onNoCD {
    g_noCD = !g_noCD;
    if (g_noCD) {
        [_noCDBtn setTitle:@"✅ 无CD: 开" forState:UIControlStateNormal];
        _noCDBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95];
    } else {
        [_noCDBtn setTitle:@"❌ 无CD: 关" forState:UIControlStateNormal];
        _noCDBtn.backgroundColor = [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
    }
    applyOrRestorePatches();
}

- (void)onNoEnergy {
    g_noEnergy = !g_noEnergy;
    if (g_noEnergy) {
        [_noEnergyBtn setTitle:@"✅ 无能量: 开" forState:UIControlStateNormal];
        _noEnergyBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95];
    } else {
        [_noEnergyBtn setTitle:@"❌ 无能量: 关" forState:UIControlStateNormal];
        _noEnergyBtn.backgroundColor = [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
    }
    applyOrRestorePatches();
}

/* 拖拽悬浮球 */
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject];
    CGPoint p = [t locationInView:self];
    if (CGRectContainsPoint(_toggleBtn.frame, p)) {
        _dragStart = p;
    } else if (_expanded && !CGRectContainsPoint(_panel.frame, p)) {
        /* 点击菜单外部关闭 */
        _expanded = NO;
        _panel.hidden = YES;
        self.userInteractionEnabled = NO;
    }
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject];
    CGPoint p = [t locationInView:self];
    if (CGRectContainsPoint(_toggleBtn.frame, CGPointMake(p.x - (p.x - _dragStart.x), p.y - (p.y - _dragStart.y))) ||
        _dragStart.x != 0) {
        CGFloat dx = p.x - _dragStart.x;
        CGFloat dy = p.y - _dragStart.y;
        CGRect f = _toggleBtn.frame;
        f.origin.x += dx;
        f.origin.y += dy;
        
        CGRect screen = [UIScreen mainScreen].bounds;
        f.origin.x = MAX(0, MIN(screen.size.width - f.size.width, f.origin.x));
        f.origin.y = MAX(50, MIN(screen.size.height - f.size.height - 50, f.origin.y));
        
        _toggleBtn.frame = f;
        _dragStart = p;
        
        if (_expanded) [self layoutPanel];
    }
}

/* 让触摸事件正确传递：面板和按钮需要能接收事件 */
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!_expanded) {
        /* 菜单关闭时，只有悬浮球响应 */
        if (CGRectContainsPoint(_toggleBtn.frame, point)) {
            return _toggleBtn;
        }
        return nil; /* 传递给下层 */
    }
    
    /* 菜单展开时，面板和按钮响应 */
    if (CGRectContainsPoint(_panel.frame, point)) {
        return [_panel hitTest:[self convertPoint:point toView:_panel] withEvent:event];
    }
    if (CGRectContainsPoint(_toggleBtn.frame, point)) {
        return _toggleBtn;
    }
    
    /* 点击面板外部关闭菜单 */
    _expanded = NO;
    _panel.hidden = YES;
    self.userInteractionEnabled = NO;
    return nil;
}

@end

/* ====== 启动 ====== */
static void showMenu(void) {
    static JYJHMenuWindow *menuWin = nil;
    if (menuWin) return;
    
    menuWin = [[JYJHMenuWindow alloc] init];
    [menuWin setHidden:NO];
    [menuWin makeKeyAndVisible];
    /* 不让它成为key window太久，让游戏正常接收输入 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        /* 重新让游戏window成为key */
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w != menuWin && !w.isHidden) {
                [w makeKeyAndVisible];
                break;
            }
        }
    });
}

__attribute__((constructor))
static void initialize(void) {
    LOG(@"JYJH v3.1 loaded (v1.10.1 offsets)");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        applyOrRestorePatches();
        showMenu();
    });
}