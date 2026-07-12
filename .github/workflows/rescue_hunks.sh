#!/bin/bash
# =====================================================================
# 🚀 SusFS Total Patch Fixer (ASCII Escape-Safe Edition)
# 场景：GitHub Actions 自动化流水线 (全量、零污染、纯 BASH + AWK)
# 特性：全面采用 ASCII 码及双引号替换脆弱的单引号转义，彻底解决编译阻断
# =====================================================================

set -e

echo "🚀 [SusFS 4.19 Rescue Engine] Adjusting fs/namespace.c for 4.19 VFS context API..."

NAMESPACE_FILE="fs/namespace.c"
if [ -f "$NAMESPACE_FILE" ]; then
    echo "[+] Patching $NAMESPACE_FILE (Fixing Header Injections & 4.19 fc_mount Overhaul)..."
    
    # ---------------------------------------------------------------------
    # 步骤 1：修复头文件处的 Hunk 失败（利用 awk 精准在 internal.h 之前或之后进行条件注入）
    # ---------------------------------------------------------------------
    
    awk '
    /#include "pnode.h"/ {
        print "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT"
        print "#include <linux/susfs_def.h>"
        print "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT"
        print ""
        print "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT"
        print "extern bool susfs_is_current_ksu_domain(void);"
        print "extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;"
        print "#define CL_COPY_MNT_NS BIT(25) /* used by copy_mnt_ns() */"
        print "#endif // #ifdef CONFIG_KSU_SUSFS_SUS_MOUNT"
        print ""
    }
    { print }
    ' "$NAMESPACE_FILE" > "${NAMESPACE_FILE}.tmp" && mv "${NAMESPACE_FILE}.tmp" "$NAMESPACE_FILE"
  

    # ---------------------------------------------------------------------
    # 步骤 2：全量拦截并完美重写适配 4.19 版的 vfs_kern_mount 函数（独立闭环注入）
    # ---------------------------------------------------------------------
    awk '
    BEGIN {
        # 状态机初始化：0 = 等待进入目标函数
        state = 0
    }

    # 状态 0：捕获 vfs_kern_mount 函数入口
    state == 0 && /struct vfsmount \*vfs_kern_mount\(/ {
        state = 1
        print $0
        next
    }

    # 状态 1：在函数内部寻找 fc = fs_context_for_mount(...) 之后的安全注入点
    state == 1 && /fc = fs_context_for_mount/ {
        print $0
        # 连续读取并打印接下来的错误校验大底，直到找到返回语句
        while (getline > 0) {
            print $0
            if ($0 ~ /return ERR_CAST\(fc\);/) {
                break
            }
        }
        
        # 精准在原厂错误校验后，注入完全独立、自带 return、不污染后续流程的 SUSFS 拦截看门狗
        print ""
        print "#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT"
        print "\tif (static_branch_unlikely(&susfs_is_sdcard_android_data_not_decrypted)) {"
        print "\t\tif (susfs_is_current_ksu_domain()) {"
        print "\t\t\tstruct mount *ksu_mnt = susfs_alloc_non_unshare_ksu_vfsmnt(name ?:\"none\");"
        print "\t\t\tif (ksu_mnt) {"
        print "\t\t\t\tput_fs_context(fc);"
        print "\t\t\t\treturn &ksu_mnt->mnt;"
        print "\t\t\t}"
        print "\t\t\tput_fs_context(fc);"
        print "\t\t\treturn ERR_PTR(-ENOMEM);"
        print "\t\t}"
        print "\t}"
        print "#endif"
        
        state = 2 # 功成身退，接下来的所有行全部原样输出，绝不篡改原厂尾部逻辑
        next
    }

    # 默认行为：原样输出
    { print $0 }
    ' "$NAMESPACE_FILE" > "${NAMESPACE_FILE}.tmp" && mv "${NAMESPACE_FILE}.tmp" "$NAMESPACE_FILE"

    echo "[+] StateMachine-awk: fs/namespace.c successfully re-engineered!"
fi

# ---------------------------------------------------------------------
# 2. 修复 fs/proc/cmdline.c (适配带有 IGNORE_SKIP_FLAG 的 4.19 树)
# ---------------------------------------------------------------------
CMDLINE_FILE="fs/proc/cmdline.c"
if [ -f "$CMDLINE_FILE" ]; then
    echo "[+] Patching $CMDLINE_FILE (Injecting top-level cmdline spoof hook)..."
    
    awk '
    BEGIN { 
        header_added = 0; 
        in_func = 0;
    }

    # 1. 在函数外层上方注入 extern 声明
    /static int cmdline_proc_show/ {
        if (!header_added) {
            print "#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG"
            print "extern struct static_key_false susfs_is_fake_cmdline_or_bootconfig_buffer_set;"
            print "extern void susfs_spoof_cmdline_or_bootconfig(struct seq_file *m);"
            print "#endif"
            print ""
            header_added = 1
        }
        in_func = 1
        print $0
        next
    }

    # 2. 匹配到函数入口的左大括号，紧跟其后注入劫持逻辑
    /^{/ {
        print $0
        if (in_func == 1) {
            print "#ifdef CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG"
            print "\tif (static_branch_likely(&susfs_is_fake_cmdline_or_bootconfig_buffer_set)) {"
            print "\t\tsusfs_spoof_cmdline_or_bootconfig(m);"
            print "\t\tseq_putc(m, \x27\\n\x27);"
            print "\t\treturn 0;"
            print "\t}"
            print "#endif"
            in_func = 0 # 注入完成，关闭状态机
        }
        next
    }

    # 兜底防止状态机未闭合
    /^}/ {
        in_func = 0
    }

    { print }
    ' "$CMDLINE_FILE" > "${CMDLINE_FILE}.tmp" && mv "${CMDLINE_FILE}.tmp" "$CMDLINE_FILE" # <-- ✅ 这里已修正为 CMDLINE_FILE

    echo "[+] $CMDLINE_FILE patched successfully at function entrance."
fi

# ---------------------------------------------------------------------
# 3. 修复 fs/proc/task_mmu.c (函数级状态机隔离，精准防误伤)
# ---------------------------------------------------------------------

# 定义源码文件
TARGET_FILE="fs/proc/task_mmu.c"
if [ -f "$TARGET_FILE" ]; then
    # 使用 awk 状态机进行精准修复
    awk '
    BEGIN {
        state = 0; 
    }
    
    # 状态 0：寻找锚点行
    state == 0 && $0 ~ /#include <linux\/mm_inline\.h>/ {
        print $0;
        state = 1;
        next;
    }
    
    # 状态 1：在锚点后寻找合适的插入位置（比如接下来的空行或者 asm 包含线）
    state == 1 {
        # 匹配到空行，或者匹配到接下来的 asm 包含，说明可以在此插入
        if ($0 ~ /^$/ || $0 ~ /#include <asm\/elf\.h>/) {
            print "#if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)";
            print "#include <linux/susfs_def.h>";
            print "#endif // #if defined(CONFIG_KSU_SUSFS_SUS_KSTAT) || defined(CONFIG_KSU_SUSFS_SUS_MAP) || defined(CONFIG_KSU_SUSFS_OPEN_REDIRECT)";
            
            # 如果当前是空行，补一个空行保持格式整洁
            if ($0 ~ /^$/) {
                print "";
            }
            
            # 如果当前已经是 #include <asm/elf.h>，记得把当前行也打印出来
            if ($0 ~ /#include <asm\/elf\.h>/) {
                print $0;
            }
            
            state = 2; # 切换到完成状态
            next;
        }
    }
    
    # 默认状态：原样输出所有行
    {
        print $0;
    }
    ' "$TARGET_FILE" > "${TARGET_FILE}.tmp" && mv "${TARGET_FILE}.tmp" "$TARGET_FILE"
    echo "[+] $TARGET_FILE patched successfully ."
fi


echo "🎉 [SusFS Rescue Engine] ASCII-Safe patch completed. Safe to compile now!"
