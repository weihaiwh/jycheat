/**
 * 剑影江湖 v1.10.1 - 无CD无能量 v4.1
 * 修复悬浮球交互：手动处理触摸事件，避免gesture冲突
 */

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <UIKit/UIKit.h>

extern void NSLog(NSString *format, ...) __attribute__((format(NSString, 1, 2)));
extern void sys_icache_invalidate(void *start, size_t len);

#define LOG(fmt, args...) NSLog(@"[JYJH] " fmt, ##args)

static const uint64_t OFF_CheckSkillAttackCanUse = 0x30741B8;
static const uint64_t OFF_CheckSkillIsReady       = 0x3074B54;
static const uint32_t ARM64_MOV_W0_1 = 0x52800020;
static const uint32_t ARM64_RET      = 0xD65F03C0;

static uint64_t g_base = 0;
static BOOL g_noCD = YES;
static BOOL g_noEnergy = YES;
static uint32_t g_orig1[2] = {0, 0};
static uint32_t g_orig2[2] = {0, 0};

static UIView *g_panel = nil;
static UIButton *g_btnCD = nil;
static UIButton *g_btnEnergy = nil;
static BOOL g_panelOpen = NO;

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

/* ====== UI辅助 ====== */
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
    /* 面板相对于球定位 */
    UIView *ballView = nil;
    for (UIView *v in [[UIApplication sharedApplication].keyWindow subviews]) {
        if ([v isKindOfClass:NSClassFromString(@"JYJHBallView")]) { ballView = v; break; }
    }
    if (!ballView || !g_panel) return;
    CGRect bf = ballView.frame;
    CGRect sc = [UIScreen mainScreen].bounds;
    CGFloat pw = 180, ph = 150;
    CGFloat px = bf.origin.x - pw - 8;
    if (px < 4) px = bf.origin.x + bf.size.width + 8;
    CGFloat py = bf.origin.y + bf.size.height/2 - ph/2;
    if (py < 4) py = 4;
    if (py + ph > sc.size.height - 4) py = sc.size.height - ph - 4;
    g_panel.frame = CGRectMake(px, py, pw, ph);
}

static void togglePanel(void) {
    g_panelOpen = !g_panelOpen;
    g_panel.hidden = !g_panelOpen;
    if (g_panelOpen) layoutPanel();
}

static void onCD(void) { g_noCD = !g_noCD; refreshButtons(); doPatch(); }
static void onEnergy(void) { g_noEnergy = !g_noEnergy; refreshButtons(); doPatch(); }

/* ====== 悬浮球View - 手动处理触摸，不用gesture ====== */
@interface JYJHBallView : UIView {
    CGPoint _touchStart;
    BOOL _isDragging;
    NSUInteger _touchCount;
}
@end

@implementation JYJHBallView

- (instancetype)init {
    self = [super initWithFrame:CGRectMake([UIScreen mainScreen].bounds.size.width - 54, 100, 44, 44)];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.5 blue:0.95 alpha:0.9];
        self.layer.cornerRadius = 22;
        self.userInteractionEnabled = YES;
        self.multipleTouchEnabled = NO;
        
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
        lbl.text = @"剑";
        lbl.textColor = [UIColor whiteColor];
        lbl.font = [UIFont boldSystemFontOfSize:18];
        lbl.textAlignment = NSTextAlignmentCenter;
        [self addSubview:lbl];
        
        _isDragging = NO;
        _touchCount = 0;
    }
    return self;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    /* 扩大点击区域到周围8px */
    CGRect expanded = CGRectInset(self.bounds, -8, -8);
    return CGRectContainsPoint(expanded, point);
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesBegan:touches withEvent:event];
    UITouch *t = [touches anyObject];
    _touchStart = [t locationInView:self.superview];
    _isDragging = NO;
    _touchCount = 1;
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesMoved:touches withEvent:event];
    UITouch *t = [touches anyObject];
    CGPoint cur = [t locationInView:self.superview];
    CGFloat dx = cur.x - _touchStart.x;
    CGFloat dy = cur.y - _touchStart.y;
    
    /* 移动超过5px才算拖拽 */
    if (fabs(dx) > 5 || fabs(dy) > 5) {
        _isDragging = YES;
        CGRect f = self.frame;
        CGRect sc = [UIScreen mainScreen].bounds;
        f.origin.x = MAX(0, MIN(sc.size.width - f.size.width, f.origin.x + dx));
        f.origin.y = MAX(50, MIN(sc.size.height - f.size.height - 50, f.origin.y + dy));
        self.frame = f;
        _touchStart = cur;
        
        if (g_panelOpen) layoutPanel();
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesEnded:touches withEvent:event];
    if (!_isDragging) {
        /* 短按 = 点击，展开菜单 */
        togglePanel();
    }
    _isDragging = NO;
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    [super touchesCancelled:touches withEvent:event];
    _isDragging = NO;
}

@end

/* ====== 初始化 ====== */
/* ====== Action Handler ====== */
@interface JYJHActionHandler : NSObject
+ (instancetype)shared;
- (void)onCD;
- (void)onEnergy;
@end
static void setupUI(void) {
    UIWindow *win = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow && !w.isHidden) { win = w; break; }
    }
    if (!win) {
        NSArray *ws = [UIApplication sharedApplication].windows;
        for (UIWindow *w in ws) { if (!w.isHidden) { win = w; break; } }
    }
    if (!win) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ setupUI(); });
        return;
    }
    
    LOG(@"keyWindow: %@", win);
    
    /* 悬浮球 */
    JYJHBallView *ball = [[JYJHBallView alloc] init];
    [win addSubview:ball];
    LOG(@"Ball added at %@", NSStringFromCGRect(ball.frame));
    
    /* 面板 */
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
    
    /* 用普通UIButton + target-action，最可靠的方式 */
    g_btnCD = [UIButton buttonWithType:UIButtonTypeCustom];
    g_btnCD.frame = CGRectMake(12, 42, 156, 40);
    g_btnCD.layer.cornerRadius = 10;
    [g_panel addSubview:g_btnCD];
    
    g_btnEnergy = [UIButton buttonWithType:UIButtonTypeCustom];
    g_btnEnergy.frame = CGRectMake(12, 92, 156, 40);
    g_btnEnergy.layer.cornerRadius = 10;
    [g_panel addSubview:g_btnEnergy];
    
    /* 用objc_setAssociatedObject绑定handler到按钮 */
    /* 实际上直接用addTarget更简单 */
    [g_btnCD addTarget:[JYJHActionHandler shared] action:@selector(onCD) forControlEvents:UIControlEventTouchUpInside];
    [g_btnEnergy addTarget:[JYJHActionHandler shared] action:@selector(onEnergy) forControlEvents:UIControlEventTouchUpInside];
    
    refreshButtons();
}


@implementation JYJHActionHandler

+ (instancetype)shared {
    static JYJHActionHandler *s = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [[self alloc] init]; });
    return s;
}

- (void)onCD { onCD(); }
- (void)onEnergy { onEnergy(); }

@end

__attribute__((constructor))
static void initialize(void) {
    LOG(@"JYJH v4.1 loaded");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        doPatch();
        setupUI();
    });
}
