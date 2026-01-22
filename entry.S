# =============================================================================
# xv6 内核入口 (entry.S)
# =============================================================================
#
# 【启动流程概述】
# 这是 xv6 内核的入口点。bootmain.c 加载完内核后，跳转到这里。
# 此时 CPU 处于保护模式，但分页尚未启用。
#
# 【主要任务】
# 1. 启用分页机制（设置 CR3 和 CR0 的 PG 位）
# 2. 设置内核栈指针
# 3. 跳转到 C 语言的 main() 函数
#
# 【虚拟内存】
# xv6 内核运行在高地址（KERNBASE = 0x80000000 以上）
# 但物理内存从 0 开始，所以需要页表来映射
# entrypgdir 是一个简单的启动页表，将：
#   - VA [0, 4MB) -> PA [0, 4MB)         (恒等映射，用于过渡)
#   - VA [KERNBASE, KERNBASE+4MB) -> PA [0, 4MB)  (高地址映射)
#
# 【启动链路】
# BIOS -> bootasm.S -> bootmain.c -> entry.S (本文件) -> main.c
# =============================================================================

# The xv6 kernel starts executing in this file. This file is linked with
# the kernel C code, so it can refer to kernel symbols such as main().
# The boot block (bootasm.S and bootmain.c) jumps to entry below.

# =============================================================================
# Multiboot 头（用于 GRUB 等引导加载器）
# =============================================================================
# Multiboot header, for multiboot boot loaders like GNU Grub.
# http://www.gnu.org/software/grub/manual/multiboot/multiboot.html
#
# Using GRUB 2, you can boot xv6 from a file stored in a
# Linux file system by copying kernel or kernelmemfs to /boot
# and then adding this menu entry:
#
# menuentry "xv6" {
# 	insmod ext2
# 	set root='(hd0,msdos1)'
# 	set kernel='/boot/kernel'
# 	echo "Loading ${kernel}..."
# 	multiboot ${kernel} ${kernel}
# 	boot
# }

#include "asm.h"
#include "memlayout.h"
#include "mmu.h"
#include "param.h"

# Multiboot header.  Data to direct multiboot loader.
# Multiboot 头数据，供 multiboot 兼容的引导加载器使用
.p2align 2
.text
.globl multiboot_header
multiboot_header:
  #define magic 0x1badb002              # Multiboot 魔数
  #define flags 0                       # 标志位
  .long magic
  .long flags
  .long (-magic-flags)                  # 校验和：magic + flags + checksum = 0

# =============================================================================
# 【内核入口点】
# =============================================================================
# By convention, the _start symbol specifies the ELF entry point.
# Since we haven't set up virtual memory yet, our entry point is
# the physical address of 'entry'.
# 按照惯例，_start 符号指定 ELF 入口点
# 由于尚未设置虚拟内存，入口点是 entry 的物理地址
.globl _start
_start = V2P_WO(entry)      # _start = entry 的物理地址（entry - KERNBASE）

# =============================================================================
# 【entry - 内核真正的入口】
# 启动处理器在这里开始执行，此时分页尚未开启
# =============================================================================
# Entering xv6 on boot processor, with paging off.
# 启动处理器从这里进入 xv6，此时分页关闭
.globl entry
entry:
  # ===========================================================================
  # 【启动信息】在 VGA 显存打印内核入口标记
  # ===========================================================================
  # 保存寄存器
  pushl   %eax
  pushl   %ebx
  
  # 计算 VGA 显存位置（第 3 行开始，因为 bootmain 已打印了 3 行）
  # VGA 文本模式显存地址：0xB8000
  # 每行 80 个字符，每个字符 2 字节
  movl    $0xB8000, %ebx
  addl    $(3 * 80 * 2), %ebx           # 跳到第 4 行
  
  # 打印 "[BOOT] kernel entry\n"
  movb    $'[', %al
  movb    $0x0F, %ah                     # 白色文字
  movw    %ax, (%ebx)
  addl    $2, %ebx
  movb    $'B', %al
  movw    %ax, (%ebx)
  addl    $2, %ebx
  movb    $'O', %al
  movw    %ax, (%ebx)
  addl    $2, %ebx
  movb    $'O', %al
  movw    %ax, (%ebx)
  addl    $2, %ebx
  movb    $'T', %al
  movw    %ax, (%ebx)
  addl    $2, %ebx
  movb    $']', %al
  movw    %ax, (%ebx)
  addl    $2, %ebx
  movb    $' ', %al
  movw    %ax, (%ebx)
  addl    $2, %ebx
  movb    $'k', %al
  movw    %ax, (%ebx)
  addl    $2, %ebx
  movb    $'e', %al
  movw    %ax, (%ebx)
  addl    $2, %ebx
  movb    $'r', %al
  movw    %ax, (%ebx)
  addl    $2, %ebx
  movb    $'n', %al
  movw    %ax, (%ebx)
  addl    $2, %ebx
  movb    $'e', %al
  movw    %ax, (%ebx)
  addl    $2, %ebx
  movb    $'l', %al
  movw    %ax, (%ebx)
  addl    $2, %ebx
  movb    $' ', %al
  movw    %ax, (%ebx)
  addl    $2, %ebx
  movb    $'e', %al
  movw    %ax, (%ebx)
  addl    $2, %ebx
  movb    $'n', %al
  movw    %ax, (%ebx)
  addl    $2, %ebx
  movb    $'t', %al
  movw    %ax, (%ebx)
  addl    $2, %ebx
  movb    $'r', %al
  movw    %ax, (%ebx)
  addl    $2, %ebx
  movb    $'y', %al
  movw    %ax, (%ebx)
  
  # 恢复寄存器
  popl    %ebx
  popl    %eax
  
  # ===========================================================================
  # 【启用 4MB 大页支持】
  # 设置 CR4 的 PSE 位（Page Size Extension）
  # 这样页目录项可以直接映射 4MB 的物理页面，无需二级页表
  # ===========================================================================
  # Turn on page size extension for 4Mbyte pages
  movl    %cr4, %eax
  orl     $(CR4_PSE), %eax              # 设置 PSE 位
  movl    %eax, %cr4

  # ===========================================================================
  # 【设置页目录】
  # 将 entrypgdir 的物理地址加载到 CR3 寄存器
  # CR3 存放页目录的物理地址，是分页机制的核心
  # ===========================================================================
  # Set page directory  设置页目录
  movl    $(V2P_WO(entrypgdir)), %eax   # entrypgdir 的物理地址
  movl    %eax, %cr3                     # CR3 = 页目录物理地址

  # ===========================================================================
  # 【启用分页】
  # 设置 CR0 的 PG 位（Paging）和 WP 位（Write Protect）
  # 从此刻起，所有内存访问都经过页表转换！
  # ===========================================================================
  # Turn on paging.  开启分页
  movl    %cr0, %eax
  orl     $(CR0_PG|CR0_WP), %eax        # 设置 PG 和 WP 位
  movl    %eax, %cr0                     # 分页正式启用！

  # ===========================================================================
  # 【设置内核栈】
  # 栈指向 stack + KSTACKSIZE（栈顶）
  # stack 是在本文件末尾定义的 KSTACKSIZE 字节的空间
  # 栈向下增长
  # ===========================================================================
  # Set up the stack pointer.  设置栈指针
  movl $(stack + KSTACKSIZE), %esp      # esp = 内核栈顶

  # ===========================================================================
  # 【跳转到 main()】
  # 使用间接跳转而非直接跳转，因为直接跳转会生成相对地址指令
  # 而我们需要跳转到高地址（虚拟地址）的 main 函数
  # 从此进入 C 代码的世界！
  # ===========================================================================
  # Jump to main(), and switch to executing at
  # high addresses. The indirect call is needed because
  # the assembler produces a PC-relative instruction
  # for a direct jump.
  # 跳转到 main()，切换到高地址执行
  # 使用间接跳转是因为汇编器会为直接跳转生成 PC 相对指令
  mov $main, %eax                        # eax = main 函数的虚拟地址
  jmp *%eax                              # 跳转到 main()！

# =============================================================================
# 【内核栈空间】
# .comm 指令在 BSS 段分配 KSTACKSIZE 字节的空间作为启动栈
# =============================================================================
.comm stack, KSTACKSIZE                  # 分配内核栈空间
