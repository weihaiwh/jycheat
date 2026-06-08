/**
 * 剑影江湖 (com.jyjh.whwb) v1.10.1 - 无CD无能量技能插件
 * v3.2: 修复悬浮菜单
 */

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
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
static uint32_t g_orig1[2] = {0, 0};
static uint32_t g_orig2[2] = {0, 0};

/* UI 全局 */
static UIView *g_rootView = nil;
static UIButton *g_ball = nil;
static UIView *g_panel = nil;
static UIButton *g_btnCD = nil;
static UIButton *g_btnEnergy = nil;
static BOOL g_open = NO;

/* ====== 内存补丁 ====== */
static kern_return_t patchMem(void *addr, const void *data, size_t sz) {
    vm_address_t pg = (vm_address_t)addr & ~(vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), pg, vm_page_size, 0,
                                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS)
        kr = vm_protect(mach_task_self(), pg, vm_page_size, 0, VM_PROT_ALL);
    if (kr != KERN_SUCCESS) return kr;
    memcpy(addr, data, sz);
    sys_icache_invalidate(addr, sz);
    vm_protect(mach_task_self(), pg, vm_page_size, 0, VM_PROT_READ | VM_PROT_EXECUTE);
    return KERN_SUCCESS;
}

static uint64_t findBase(const char *name) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (n && strstr(n, name)) return (uint64_t)_dyld_get_image_header(i);
    }
    return 0;
}

static void doPatch(void) {
    if (!g_base) {
        g_base = findBase("FrameSync.code.dll");
        if (!g_base) return;
        memcpy(g_orig1, (void *)(g_base + OFF_CheckSkillAttackCanUse), 8);
        memcpy(g_orig2, (void *)(g_base + OFF_CheckSkillIsReady), 8);
    }
    uint32_t p[] = { ARM64_MOV_W0_1, ARM64_RET };
    if (g_noCD) patchMem((void *)(g_base + OFF_CheckSkillAttackCanUse), p, 8);
    else if (g_orig1[0]) patchMem((void *)(g_base + OFF_CheckSkillAttackCanUse), g_orig1, 8);
    if (g_noEnergy) patchMem((void *)(g_base + OFF_CheckSkillIsReady), p, 8);
    else if (g_orig2[0]) patchMem((void *)(g_base + OFF_CheckSkillIsReady), g_orig2, 8);
}

/* ====== UI 辅助函数 ====== */
static void refreshButtons(void) {
    [g_btnCD setTitle: g_noCD ? @"✅ 无CD: 开" : @"❌ 无CD: 关" forState:UIControlStateNormal];
    g_btnCD.backgroundColor = g_noCD ?
        [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] :
        [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
    [g_btnEnergy setTitle: g_noEnergy ? @"✅ 无能量: 开" : @"❌ 无能量: 关" forState:UIControlStateNormal];
    g_btnEnergy.backgroundColor = g_noEnergy ?
        [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] :
        [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
}

static void layoutPanel(void) {
    if (!g_ball || !g_panel) return;
    CGRect bf = g_ball.frame;
    CGRect sc = [UIScreen mainScreen].bounds;
    CGFloat pw = 180, ph = 150;
    CGFloat px = bf.origin.x - pw - 8;
    if (px < 4) px = bf.origin.x + bf.size.width + 8;
    CGFloat py = bf.origin.y + bf.size.height/2 - ph/2;
    if (py < 4) py = 4;
    if (py + ph > sc.size.height - 4) py = sc.size.height - ph - 4;
    g_panel.frame = CGRectMake(px, py, pw, ph);
}

/* ====== ObjC Target ====== */

@interface JYJHHandler : NSObject
- (void)tapBall;
- (void)tapCD;
- (void)tapEnergy;
- (void)drag:(UIPanGestureRecognizer *)pan;
- (void)tapBg:(UITapGestureRecognizer *)tap;
@end

@implementation JYJHHandler

- (void)tapBall {
    g_open = !g_open;
    g_panel.hidden = !g_open;
    if (g_open) layoutPanel();
}

- (void)tapCD {
    g_noCD = !g_noCD;
    refreshButtons();
    doPatch();
}

- (void)tapEnergy {
    g_noEnergy = !g_noEnergy;
    refreshButtons();
    doPatch();
}

- (void)drag:(UIPanGestureRecognizer *)pan {
    CGPoint t = [pan translationInView:g_rootView];
    CGRect f = g_ball.frame;
    CGRect sc = [UIScreen mainScreen].bounds;
    f.origin.x = MAX(0, MIN(sc.size.width - f.size.width, f.origin.x + t.x));
    f.origin.y = MAX(50, MIN(sc.size.height - f.size.height - 50, f.origin.y + t.y));
    g_ball.frame = f;
    [pan setTranslation:CGPointZero inView:g_rootView];
    if (g_open) layoutPanel();
}

- (void)tapBg:(UITapGestureRecognizer *)tap {
    if (!g_open) return;
    CGPoint p = [tap locationInView:g_rootView];
    if (!CGRectContainsPoint(g_ball.frame, p) && !CGRectContainsPoint(g_panel.frame, p)) {
        g_open = NO;
        g_panel.hidden = YES;
    }
}

@end

static JYJHHandler *g_handler = nil;

/* ====== 创建菜单 ====== */
static void setupMenu(void) {
    if (g_rootView) return;
    
    UIWindow *win = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow) { win = w; break; }
    }
    if (!win) {
        NSArray *ws = [UIApplication sharedApplication].windows;
        if (ws.count) win = ws.lastObject;
    }
    if (!win) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ setupMenu(); });
        return;
    }
    
    g_handler = [[JYJHHandler alloc] init];
    
    CGRect sc = [UIScreen mainScreen].bounds;
    
    /* 全屏透明容器 */
    g_rootView = [[UIView alloc] initWithFrame:sc];
    g_rootView.backgroundColor = [UIColor clearColor];
    g_rootView.userInteractionEnabled = YES;
    [win addSubview:g_rootView];
    
    /* 悬浮球 */
    g_ball = [UIButton buttonWithType:UIButtonTypeCustom];
    g_ball.frame = CGRectMake(sc.size.width - 54, 200, 44, 44);
    g_ball.backgroundColor = [UIColor colorWithRed:0.1 green:0.5 blue:0.95 alpha:0.9];
    g_ball.layer.cornerRadius = 22;
    [g_ball setTitle:@"剑" forState:UIControlStateNormal];
    g_ball.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    [g_ball addTarget:g_handler action:@selector(tapBall) forControlEvents:UIControlEventTouchUpInside];
    [g_rootView addSubview:g_ball];
    
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:g_handler action:@selector(drag:)];
    [g_ball addGestureRecognizer:pan];
    
    /* 菜单面板 - 加到window上避免被裁剪 */
    g_panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 180, 150)];
    g_panel.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.18 alpha:0.97];
    g_panel.layer.cornerRadius = 14;
    g_panel.hidden = YES;
    [win addSubview:g_panel];
    
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 10, 180, 22)];
    title.text = @"剑影江湖 v1.10.1";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:14];
    title.textAlignment = NSTextAlignmentCenter;
    [g_panel addSubview:title];
    
    g_btnCD = [UIButton buttonWithType:UIButtonTypeCustom];
    g_btnCD.frame = CGRectMake(12, 42, 156, 40);
    g_btnCD.layer.cornerRadius = 10;
    [g_btnCD addTarget:g_handler action:@selector(tapCD) forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:g_btnCD];
    
    g_btnEnergy = [UIButton buttonWithType:UIButtonTypeCustom];
    g_btnEnergy.frame = CGRectMake(12, 92, 156, 40);
    g_btnEnergy.layer.cornerRadius = 10;
    [g_btnEnergy addTarget:g_handler action:@selector(tapEnergy) forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:g_btnEnergy];
    
    refreshButtons();
    
    /* 点击背景关闭 */
    UITapGestureRecognizer *bgTap = [[UITapGestureRecognizer alloc] initWithTarget:g_handler action:@selector(tapBg:)];
    bgTap.cancelsTouchesInView = NO;
    [g_rootView addGestureRecognizer:bgTap];
}

/* ====== 入口 ====== */
__attribute__((constructor))
static void initialize(void) {
    LOG(@"JYJH v3.2 loaded");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        doPatch();
        setupMenu();
    });
}