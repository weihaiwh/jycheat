/**
 * 剑影江湖 v1.10.1 - 无CD无能量 v4.2
 * 修复：用主二进制基址，不是FrameSync.code.dll
 * 
 * IL2CPP dump的偏移是主可执行文件的RVA
 * Unity把所有DLL代码编译进主二进制
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

/* 关键修复：查找主可执行文件基址，不是FrameSync.code.dll */
static uint64_t findMainBase(void) {
    /* 方法1: _dyld_get_image_header(0) 就是主可执行文件 */
    uint64_t mainBase = (uint64_t)_dyld_get_image_header(0);
    const char *name = _dyld_get_image_name(0);
    LOG(@"Main executable: %s base=0x%llx", name ? name : "null", mainBase);
    return mainBase;
}

static void doPatch(void) {
    if (!g_base) {
        g_base = findMainBase();
        if (!g_base) {
            LOG(@"ERROR: Cannot find main base!");
            return;
        }
        LOG(@"Base=0x%llx, CheckCanUse=0x%llx, CheckIsReady=0x%llx",
            g_base, g_base + OFF_CheckSkillAttackCanUse, g_base + OFF_CheckSkillIsReady);
        
        /* 保存原始指令 */
        memcpy(g_orig1, (void *)(g_base + OFF_CheckSkillAttackCanUse), 8);
        memcpy(g_orig2, (void *)(g_base + OFF_CheckSkillIsReady), 8);
        LOG(@"Orig1: %08x %08x", g_orig1[0], g_orig1[1]);
        LOG(@"Orig2: %08x %08x", g_orig2[0], g_orig2[1]);
    }
    uint32_t p[] = { ARM64_MOV_W0_1, ARM64_RET };
    if (g_noCD) {
        kern_return_t kr = patchMem((void *)(g_base + OFF_CheckSkillAttackCanUse), p, 8);
        LOG(@"Patch CheckSkillAttackCanUse: %s", kr == KERN_SUCCESS ? "OK" : "FAIL");
    } else if (g_orig1[0]) {
        patchMem((void *)(g_base + OFF_CheckSkillAttackCanUse), g_orig1, 8);
    }
    if (g_noEnergy) {
        kern_return_t kr = patchMem((void *)(g_base + OFF_CheckSkillIsReady), p, 8);
        LOG(@"Patch CheckSkillIsReady: %s", kr == KERN_SUCCESS ? "OK" : "FAIL");
    } else if (g_orig2[0]) {
        patchMem((void *)(g_base + OFF_CheckSkillIsReady), g_orig2, 8);
    }
}

/* ====== UI ====== */
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

static void layoutPanel(UIView *ballView) {
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

static void togglePanel(UIView *ballView) {
    g_panelOpen = !g_panelOpen;
    g_panel.hidden = !g_panelOpen;
    if (g_panelOpen) layoutPanel(ballView);
}

/* ====== Action Handler ====== */
@interface JYJHActionHandler : NSObject
+ (instancetype)shared;
- (void)onCD;
- (void)onEnergy;
@end

@implementation JYJHActionHandler
+ (instancetype)shared {
    static JYJHActionHandler *s = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ s = [[self alloc] init]; });
    return s;
}
- (void)onCD { g_noCD = !g_noCD; refreshButtons(); doPatch(); }
- (void)onEnergy { g_noEnergy = !g_noEnergy; refreshButtons(); doPatch(); }
@end

/* ====== 悬浮球 ====== */
@interface JYJHBallView : UIView {
    CGPoint _touchStart;
    BOOL _isDragging;
}
@end

@implementation JYJHBallView

- (instancetype)init {
    self = [super initWithFrame:CGRectMake([UIScreen mainScreen].bounds.size.width - 54, 100, 44, 44)];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:0.1 green:0.5 blue:0.95 alpha:0.9];
        self.layer.cornerRadius = 22;
        self.userInteractionEnabled = YES;
        
        UILabel *lbl = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
        lbl.text = @"剑";
        lbl.textColor = [UIColor whiteColor];
        lbl.font = [UIFont boldSystemFontOfSize:18];
        lbl.textAlignment = NSTextAlignmentCenter;
        [self addSubview:lbl];
    }
    return self;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGRect r = CGRectInset(self.bounds, -8, -8);
    return CGRectContainsPoint(r, point);
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject];
    _touchStart = [t locationInView:self.superview];
    _isDragging = NO;
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject];
    CGPoint cur = [t locationInView:self.superview];
    CGFloat dx = cur.x - _touchStart.x;
    CGFloat dy = cur.y - _touchStart.y;
    if (fabs(dx) > 5 || fabs(dy) > 5) {
        _isDragging = YES;
        CGRect f = self.frame;
        CGRect sc = [UIScreen mainScreen].bounds;
        f.origin.x = MAX(0, MIN(sc.size.width - f.size.width, f.origin.x + dx));
        f.origin.y = MAX(50, MIN(sc.size.height - f.size.height - 50, f.origin.y + dy));
        self.frame = f;
        _touchStart = cur;
        if (g_panelOpen) layoutPanel(self);
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if (!_isDragging) togglePanel(self);
    _isDragging = NO;
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    _isDragging = NO;
}

@end

/* ====== 初始化 ====== */
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
    
    JYJHBallView *ball = [[JYJHBallView alloc] init];
    [win addSubview:ball];
    
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
    [g_btnCD addTarget:[JYJHActionHandler shared] action:@selector(onCD) forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:g_btnCD];
    
    g_btnEnergy = [UIButton buttonWithType:UIButtonTypeCustom];
    g_btnEnergy.frame = CGRectMake(12, 92, 156, 40);
    g_btnEnergy.layer.cornerRadius = 10;
    [g_btnEnergy addTarget:[JYJHActionHandler shared] action:@selector(onEnergy) forControlEvents:UIControlEventTouchUpInside];
    [g_panel addSubview:g_btnEnergy];
    
    refreshButtons();
}

__attribute__((constructor))
static void initialize(void) {
    LOG(@"JYJH v4.2 loaded - using main executable base");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        doPatch();
        setupUI();
    });
}
