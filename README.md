# 剑影江湖 (com.jyjh.whwb) 无CD无能量技能插件

## 功能
- ✅ 无CD: 所有技能无冷却，连续释放
- ✅ 无能量: 大招无需怒气/能量

## 技术原理 (v2.0 内存补丁版)

不依赖 Cydia Substrate / MSHookFunction，直接在IL2CPP函数入口写入 `return true`：

```arm64
; 原函数: CheckSkillAttackCanUse / CheckSkillIsReady
; 补丁为:
mov w0, #1    ; 0x52800020 - 返回true
ret           ; 0xD65F03C0 - 返回调用者
```

| 函数 | 偏移 | 补丁 |
|------|------|------|
| `CheckSkillAttackCanUse` | `0x2A9218` | mov w0,#1; ret |
| `CheckSkillIsReady` | `0x2A9B08` | mov w0,#1; ret |

## 部署 (iOS无根越狱)

```bash
scp JYJH_NoCDNoEnergy.dylib root@IP:/var/jb/usr/lib/TweakInject/
scp JYJH_NoCDNoEnergy.plist root@IP:/var/jb/usr/lib/TweakInject/
# 重启游戏
```

## 适配
- 设备: iPhone 13 Pro Max
- 系统: iOS 15.6
- 越狱: 无根越狱 (Dopamine/Palera1n)
- 游戏版本: 1.8.1

⚠️ 仅适用于 v1.8.1