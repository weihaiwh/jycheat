/**
 * Dobby Hook Framework - Header
 * https://github.com/jmpews/Dobby
 * 
 * Dobby is a lightweight, multi-platform, multi-architecture hook framework.
 * Used by libtool (LIBTOOL) for inline hooking on iOS.
 * 
 * Note: We only use DobbyHook. Toggle is done via global variables
 * in the hook callback functions - no need for DobbyDestroyHook.
 */

#ifndef DOBBY_H
#define DOBBY_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// DobbyHook - Inline hook a function
// target_func:  目标函数地址 (被hook的函数)
// replace_func: 替代函数地址 (hook后调用target_func会跳转到这里)
// origin_func:  输出参数, 保存原始函数的trampoline指针 (调用它等于调用原函数)
// 返回值: 0=成功, 非0=失败
int DobbyHook(void *target_func, void *replace_func, void **origin_func);

#ifdef __cplusplus
}
#endif

#endif // DOBBY_H
