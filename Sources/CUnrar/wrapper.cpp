// UnRAR source code may be used in any software to handle RAR archives without
// limitations free of charge, but cannot be used to develop RAR (WinRAR)
// compatible archiver and to re-create RAR compression algorithm, which is
// proprietary. Distribution of modified UnRAR source code in separate form
// or as a part of other software is permitted, provided that full text of
// this paragraph, starting from "UnRAR source code" words, is included in
// license, or in documentation if license is not available, and in source
// code comments of resulting package.
// Full license: ThirdParty/unrar/license.txt
#include "sources/raros.hpp" // 定义 _UNIX
#include "include/wrapper.h"
#include "sources/dll.hpp"
#include <pthread.h>
#include <string.h>
#include <string>
#include <vector>
#include <wchar.h>

namespace {

pthread_mutex_t gUnrarLock = PTHREAD_MUTEX_INITIALIZER;

// 单线程全局回调上下文（受 gUnrarLock 保护）
MRProgressCallback gCallback = nullptr;
void *gCallbackCtx = nullptr;
wchar_t gPasswordW[128] = {0};
bool gHasPassword = false;

void utf8ToWide(const char *src, wchar_t *dst, size_t dstLen) {
    if (!src || dstLen == 0) { if (dstLen) dst[0] = 0; return; }
    size_t d = 0;
    const unsigned char *p = (const unsigned char *)src;
    while (*p && d + 1 < dstLen) {
        unsigned int cp = *p;
        if (cp < 0x80) { p++; }
        else if ((cp >> 5) == 0x6) { cp = ((cp & 0x1F) << 6) | (p[1] & 0x3F); p += 2; }
        else if ((cp >> 4) == 0xE) { cp = ((cp & 0x0F) << 12) | ((p[1] & 0x3F) << 6) | (p[2] & 0x3F); p += 3; }
        else if ((cp >> 3) == 0x1E) { cp = ((cp & 0x07) << 18) | ((p[1] & 0x3F) << 12) | ((p[2] & 0x3F) << 6) | (p[3] & 0x3F); p += 4; }
        else { p++; continue; }
        if (cp < 0x10000) { dst[d++] = (wchar_t)cp; }
        else { cp -= 0x10000; dst[d++] = (wchar_t)(0xD800 + (cp >> 10)); dst[d++] = (wchar_t)(0xDC00 + (cp & 0x3FF)); }
    }
    dst[d] = 0;
}

void utf16ToUtf8(const wchar_t *src, char *dst, size_t dstLen) {
    if (dstLen == 0) return;
    dst[0] = '\0';
    if (!src) return;
    size_t d = 0;
    for (size_t i = 0; src[i] != 0 && d + 4 < dstLen; i++) {
        unsigned int cp = (unsigned int)src[i];
        if (cp >= 0xD800 && cp <= 0xDBFF && src[i + 1] >= 0xDC00 && src[i + 1] <= 0xDFFF) {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (src[i + 1] - 0xDC00);
            i++;
        }
        if (cp < 0x80) {
            dst[d++] = (char)cp;
        } else if (cp < 0x800) {
            dst[d++] = (char)(0xC0 | (cp >> 6));
            dst[d++] = (char)(0x80 | (cp & 0x3F));
        } else if (cp < 0x10000) {
            dst[d++] = (char)(0xE0 | (cp >> 12));
            dst[d++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            dst[d++] = (char)(0x80 | (cp & 0x3F));
        } else {
            dst[d++] = (char)(0xF0 | (cp >> 18));
            dst[d++] = (char)(0x80 | ((cp >> 12) & 0x3F));
            dst[d++] = (char)(0x80 | ((cp >> 6) & 0x3F));
            dst[d++] = (char)(0x80 | (cp & 0x3F));
        }
    }
    dst[d] = '\0';
}

int CALLBACK unrarCallback(UINT msg, LPARAM userData, LPARAM p1, LPARAM p2) {
    (void)userData;
    switch (msg) {
        case UCM_CHANGEVOLUMEW:
            if (gCallback) gCallback(gCallbackCtx, 1, 0, (const wchar_t *)p1);
            return 1;
        case UCM_PROCESSDATA:
            // P1 = 数据指针，P2 = 本块字节数
            if (gCallback) gCallback(gCallbackCtx, 0, (int)p2, nullptr);
            return 1;
        case UCM_NEEDPASSWORDW:
            if (gCallback) gCallback(gCallbackCtx, 2, 0, nullptr);
            if (gHasPassword && p1) {
                wcsncpy((wchar_t *)p1, gPasswordW, 127);
                ((wchar_t *)p1)[127] = 0;
                return 1;
            }
            return -1;
        case UCM_NEEDPASSWORD:
            if (gCallback) gCallback(gCallbackCtx, 2, 0, nullptr);
            if (gHasPassword && p1) {
                // char 版本：复制 UTF-8 密码
                size_t i = 0;
                const unsigned char *q = (const unsigned char *)gPasswordW;
                (void)q;
                // 简单：UTF-8 转回（密码多为 ASCII）
                size_t idx = 0;
                const unsigned char *b = (const unsigned char *)gPasswordW;
                (void)b;
                // 将 gPasswordW 转 UTF-8 到 p1
                size_t out = 0;
                const wchar_t *w = gPasswordW;
                for (size_t k = 0; w[k] != 0 && out + 3 < 127; k++) {
                    unsigned int c = (unsigned int)w[k];
                    if (c < 0x80) { ((char *)p1)[out++] = (char)c; }
                    else if (c < 0x800) { ((char *)p1)[out++] = (char)(0xC0 | (c >> 6)); ((char *)p1)[out++] = (char)(0x80 | (c & 0x3F)); }
                    else { ((char *)p1)[out++] = (char)(0xE0 | (c >> 12)); ((char *)p1)[out++] = (char)(0x80 | ((c >> 6) & 0x3F)); ((char *)p1)[out++] = (char)(0x80 | (c & 0x3F)); }
                }
                ((char *)p1)[out] = 0;
                return 1;
            }
            return -1;
        case UCM_LARGEDICT:
            if (gCallback) gCallback(gCallbackCtx, 3, 0, nullptr);
            return 1;
        default:
            return 1;
    }
}

} // namespace

extern "C" {

void *mr_archive_open(const wchar_t *path, int openMode, MRProgressCallback cb, void *cbCtx, const char *passwordUTF8, MROpenInfo *out) {
    pthread_mutex_lock(&gUnrarLock);
    gCallback = cb;
    gCallbackCtx = cbCtx;
    gHasPassword = (passwordUTF8 != nullptr && passwordUTF8[0] != 0);
    if (gHasPassword) {
        utf8ToWide(passwordUTF8, gPasswordW, 128);
    }

    std::vector<wchar_t> pathBuf;
    size_t n = path ? wcslen(path) : 0;
    pathBuf.resize(n + 1);
    if (n) memcpy(pathBuf.data(), path, (n + 1) * sizeof(wchar_t));

    RAROpenArchiveDataEx ex;
    memset(&ex, 0, sizeof(ex));
    ex.ArcNameW = pathBuf.data();
    ex.OpenMode = (unsigned int)openMode;
    ex.OpFlags = ROADOF_KEEPBROKEN;
    ex.Callback = unrarCallback;
    ex.UserData = (LPARAM)cbCtx;
    if (out) {
        ex.CmtBuf = nullptr;
        ex.CmtBufSize = 0;
    }

    void *h = RAROpenArchiveEx(&ex);

    if (out) {
        out->OpenResult = (int)ex.OpenResult;
        out->Flags = (int)ex.Flags;
        out->HasComment = (int)ex.CmtState;
    }

    if (!h) {
        pthread_mutex_unlock(&gUnrarLock);
        return nullptr;
    }
    // ERAR_MISSING_PASSWORD(22)：加密头归档，设置密码后仍可用
    if (out && ex.OpenResult != 0 && ex.OpenResult != ERAR_MISSING_PASSWORD) {
        pthread_mutex_unlock(&gUnrarLock);
        return nullptr;
    }

    if (passwordUTF8 && passwordUTF8[0]) {
        RARSetPassword(h, (char *)passwordUTF8);
    }

    // 保持锁直到 close，保证 SDK 全局状态不被并发破坏
    return h;
}

int mr_archive_close(void *handle) {
    if (!handle) return -1;
    int rc = RARCloseArchive(handle);
    pthread_mutex_unlock(&gUnrarLock);
    return rc;
}

int mr_archive_read_header(void *handle, MRHeaderInfo *out) {
    if (!handle || !out) return -1;
    RARHeaderDataEx hd;
    memset(&hd, 0, sizeof(hd));
    wchar_t fileNameExBuf[4096];
    wchar_t arcNameExBuf[2048];
    hd.FileNameEx = fileNameExBuf;
    hd.FileNameExSize = 4096;
    hd.ArcNameEx = arcNameExBuf;
    hd.ArcNameExSize = 2048;
    int rc = RARReadHeaderEx(handle, &hd);
    if (rc != ERAR_SUCCESS) return rc;

    memset(out, 0, sizeof(*out));
    memcpy(out->NameW, hd.FileNameW, sizeof(hd.FileNameW));
    memcpy(out->NameRaw, hd.FileName, sizeof(hd.FileName));
    out->NameRaw[1023] = '\0';
    utf16ToUtf8(out->NameW, out->NameUTF8, sizeof(out->NameUTF8));
    out->PackedSize = ((uint64_t)hd.PackSizeHigh << 32) | hd.PackSize;
    out->UnpackedSize = ((uint64_t)hd.UnpSizeHigh << 32) | hd.UnpSize;
    out->Flags = (int)hd.Flags;
    out->HostOS = (int)hd.HostOS;
    out->FileCRC = (int)hd.FileCRC;
    out->FileTime = (int)hd.FileTime;
    out->UnpVer = (int)hd.UnpVer;
    out->Method = (int)hd.Method;
    out->DictSize = (int)hd.DictSize;
    out->HashType = (int)hd.HashType;
    memcpy(out->Hash, hd.Hash, sizeof(out->Hash));
    return rc;
}

int mr_archive_process(void *handle, int op, const wchar_t *destPath, const wchar_t *destName, const char *passwordUTF8) {
    if (!handle) return -1;
    if (passwordUTF8 && passwordUTF8[0]) {
        RARSetPassword(handle, (char *)passwordUTF8);
    }
    wchar_t *dp = nullptr;
    std::vector<wchar_t> dpBuf;
    if (destPath) {
        size_t dn = wcslen(destPath);
        dpBuf.resize(dn + 1);
        if (dn) memcpy(dpBuf.data(), destPath, (dn + 1) * sizeof(wchar_t));
        dp = dpBuf.data();
    }
    wchar_t *dn = nullptr;
    std::vector<wchar_t> dnBuf;
    if (destName) {
        size_t nn = wcslen(destName);
        dnBuf.resize(nn + 1);
        if (nn) memcpy(dnBuf.data(), destName, (nn + 1) * sizeof(wchar_t));
        dn = dnBuf.data();
    }
    return RARProcessFileW(handle, op, dp, dn);
}

int mr_archive_comment(void *handle, wchar_t *buf, size_t buflen) {
    if (!handle || !buf || buflen == 0) return -1;
    std::wstring cmt;
    RARHeaderDataEx hd;
    memset(&hd, 0, sizeof(hd));
    wchar_t fileNameExBuf[64];
    wchar_t arcNameExBuf[64];
    hd.FileNameEx = fileNameExBuf;
    hd.FileNameExSize = 64;
    hd.ArcNameEx = arcNameExBuf;
    hd.ArcNameExSize = 64;
    // 读取注释需要 CmtBuf，UnRAR 在 ReadHeader 时填充
    // 简化：直接返回空
    buf[0] = '\0';
    return 0;
}

} // extern "C"
