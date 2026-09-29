#ifndef MACRAR_UNRAR_WRAPPER_H
#define MACRAR_UNRAR_WRAPPER_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// UnRAR SDK 桥接层（纯 C 接口，供 Swift 调用）

typedef struct MRHeaderInfo {
    wchar_t NameW[1024];       // UTF-16 文件名（UnRAR 转换后）
    char    NameRaw[1024];     // 原始字节名（用于编码修正）
    char    NameUTF8[4096];    // UTF-8 文件名
    uint64_t PackedSize;
    uint64_t UnpackedSize;
    int     Flags;
    int     HostOS;
    int     FileCRC;
    int     FileTime;
    int     UnpVer;
    int     Method;
    int     DictSize;
    int     HashType;
    unsigned char Hash[32];
} MRHeaderInfo;

typedef struct MROpenInfo {
    int Flags;                 // ROADF_* 归档标志
    int OpenResult;
    int HasComment;
} MROpenInfo;

// phase: 0=处理进度 percent 0..100, 1=换卷(name=下一卷建议名), 2=需要密码, 3=大字典
typedef void (*MRProgressCallback)(void *ctx, int phase, int percent, const wchar_t *name);

// 打开归档。openMode: 0=list, 1=extract, 2=list_incsplit
void *mr_archive_open(const wchar_t *path, int openMode, MRProgressCallback cb, void *cbCtx, const char *passwordUTF8, MROpenInfo *out);

// 0=成功, 10=归档结束, 负数=错误
int mr_archive_close(void *handle);

// 0=读到条目, 10=结束, 负数=错误
int mr_archive_read_header(void *handle, MRHeaderInfo *out);

// op: 0=skip, 1=test, 2=extract。destPath/destName 可为 NULL/空
int mr_archive_process(void *handle, int op, const wchar_t *destPath, const wchar_t *destName, const char *passwordUTF8);

// 获取归档注释（UTF-16），返回注释长度，无注释返回 0
int mr_archive_comment(void *handle, wchar_t *buf, size_t buflen);

// 设置每个文件的解压前后回调（phase: 4=开始文件 name=文件名）
void mr_archive_set_file_callback(void *handle, MRProgressCallback cb, void *cbCtx);

#ifdef __cplusplus
}
#endif

#endif