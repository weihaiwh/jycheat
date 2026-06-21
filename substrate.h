/**
 * CydiaSubstrate - MSHookFunction
 * Available on jailbroken iOS via CydiaSubstrate.framework
 * TrollStore apps can also include this framework
 */
#ifndef SUBSTRATE_H
#define SUBSTRATE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// MSHookFunction - Hook a function by replacing it
// symbol:    目标函数地址
// replace:   替代函数地址
// result:    输出参数, 保存原始函数的trampoline指针
void MSHookFunction(void *symbol, void *replace, void **result);

#ifdef __cplusplus
}
#endif

#endif // SUBSTRATE_H
