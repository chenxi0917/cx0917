#include "asm.h"
#include "memlayout.h"
#include "mmu.h"

# =============================================================================
# xv6 引导程序汇编代码 (bootasm.S)
# =============================================================================
# 
# 【启动流程概述】
# 这是 xv6 启动的第一阶段代码。BIOS 完成硬件自检后，会从硬盘第一个扇区
# （即引导扇区，512字节）加载这段代码到物理地址 0x7c00，然后跳转执行。
#
# 【主要任务】
# 1. 从 16 位实模式切换到 32 位保护模式
# 2. 设置段寄存器和栈指针
# 3. 跳转到 C 语言编写的 bootmain() 函数继续执行
#
# 【启动链路】
# BIOS -> bootasm.S (本文件) -> bootmain.c -> entry.S -> main.c
# =============================================================================

# Start the first CPU: switch to 32-bit protected mode, jump into C.
# The BIOS loads this code from the first sector of the hard disk into
# memory at physical address 0x7c00 and starts executing in real mode
# with %cs=0 %ip=7c00.

# =============================================================================
# 第一部分：16位实模式初始化
# =============================================================================
.code16                       # 告诉汇编器生成16位代码
.globl start
start:
  # -------------------------------------------------------------------------
  # 【关闭中断】
  # BIOS 启动时开启了中断，但在切换到保护模式前必须关闭中断
  # 因为实模式的中断向量表在保护模式下无效
  # -------------------------------------------------------------------------
  cli                         # BIOS enabled interrupts; disable

  # -------------------------------------------------------------------------
  # 【清零数据段寄存器】
  # 将 DS、ES、SS 段寄存器设置为 0
  # 这样在实模式下，段基址 + 偏移 = 物理地址（偏移即物理地址）
  # -------------------------------------------------------------------------
  # Zero data segment registers DS, ES, and SS.
  xorw    %ax,%ax             # Set %ax to zero  (ax = ax XOR ax = 0)
  movw    %ax,%ds             # -> Data Segment   数据段
  movw    %ax,%es             # -> Extra Segment  附加段
  movw    %ax,%ss             # -> Stack Segment  栈段

  # -------------------------------------------------------------------------
  # 【开启 A20 地址线】
  # 早期 8086 CPU 只有 20 根地址线(A0-A19)，最多寻址 1MB
  # 为了兼容旧软件，80286+ 的第 21 根地址线(A20)默认被禁用
  # 必须通过键盘控制器(端口 0x64/0x60)开启 A20，才能访问超过 1MB 的内存
  # -------------------------------------------------------------------------
  # Physical address line A20 is tied to zero so that the first PCs 
  # with 2 MB would run software that assumed 1 MB.  Undo that.
seta20.1:
  inb     $0x64,%al               # 从端口0x64读取键盘控制器状态
  testb   $0x2,%al                # 测试第2位（输入缓冲区是否满）
  jnz     seta20.1                # 如果忙则继续等待

  movb    $0xd1,%al               # 发送命令 0xd1：准备写入输出端口
  outb    %al,$0x64               # 0xd1 -> port 0x64

seta20.2:
  inb     $0x64,%al               # 再次等待键盘控制器就绪
  testb   $0x2,%al
  jnz     seta20.2

  movb    $0xdf,%al               # 发送数据 0xdf：开启 A20 地址线
  outb    %al,$0x60               # 0xdf -> port 0x60

  # -------------------------------------------------------------------------
  # 【切换到保护模式】
  # 1. 加载 GDT（全局描述符表）
  # 2. 设置 CR0 寄存器的 PE 位（Protection Enable）
  # 保护模式提供：内存保护、32位寻址、分页等高级特性
  # -------------------------------------------------------------------------
  # Switch from real to protected mode.  Use a bootstrap GDT that makes
  # virtual addresses map directly to physical addresses so that the
  # effective memory map doesn't change during the transition.
  lgdt    gdtdesc                 # 加载 GDT 描述符（包含 GDT 地址和大小）
  movl    %cr0, %eax              # 读取 CR0 寄存器
  orl     $CR0_PE, %eax           # 设置 PE 位（bit 0）= 1，开启保护模式
  movl    %eax, %cr0              # 写回 CR0，正式进入保护模式！

//PAGEBREAK!
  # -------------------------------------------------------------------------
  # 【长跳转到32位代码】
  # 通过 ljmp 指令刷新 CS 寄存器和指令预取队列
  # SEG_KCODE<<3 = 0x08，即 GDT 中的内核代码段选择子
  # 跳转后开始执行 32 位代码
  # -------------------------------------------------------------------------
  # Complete the transition to 32-bit protected mode by using a long jmp
  # to reload %cs and %eip.  The segment descriptors are set up with no
  # translation, so that the mapping is still the identity mapping.
  ljmp    $(SEG_KCODE<<3), $start32

# =============================================================================
# 第二部分：32位保护模式初始化
# =============================================================================
.code32  # Tell assembler to generate 32-bit code now.  告诉汇编器生成32位代码
start32:
  # -------------------------------------------------------------------------
  # 【设置保护模式下的段寄存器】
  # SEG_KDATA<<3 = 0x10，即 GDT 中的内核数据段选择子
  # 保护模式下段寄存器存放的是段选择子，不是段基址
  # -------------------------------------------------------------------------
  # Set up the protected-mode data segment registers
  movw    $(SEG_KDATA<<3), %ax    # Our data segment selector  数据段选择子
  movw    %ax, %ds                # -> DS: Data Segment   数据段
  movw    %ax, %es                # -> ES: Extra Segment  附加段
  movw    %ax, %ss                # -> SS: Stack Segment  栈段
  movw    $0, %ax                 # Zero segments not ready for use
  movw    %ax, %fs                # -> FS  （暂不使用）
  movw    %ax, %gs                # -> GS  （暂不使用）

  # -------------------------------------------------------------------------
  # 【设置栈指针并调用 C 代码】
  # 将栈指针设置到 0x7c00（即 start 标签的地址）
  # 栈向下增长，所以从 0x7c00 往低地址方向使用
  # 然后调用 bootmain() 函数加载内核
  # -------------------------------------------------------------------------
  # Set up the stack pointer and call into C.
  movl    $start, %esp            # 设置栈指针 esp = 0x7c00
  call    bootmain                # 调用 C 函数 bootmain()，加载内核

  # -------------------------------------------------------------------------
  # 【错误处理：bootmain 不应返回】
  # 如果 bootmain 返回（加载失败），则触发 Bochs 调试断点然后死循环
  # -------------------------------------------------------------------------
  # If bootmain returns (it shouldn't), trigger a Bochs
  # breakpoint if running under Bochs, then loop.
  movw    $0x8a00, %ax            # Bochs 调试端口命令
  movw    %ax, %dx
  outw    %ax, %dx
  movw    $0x8ae0, %ax            # 触发断点
  outw    %ax, %dx
spin:
  jmp     spin                    # 无限循环（系统挂起）

# =============================================================================
# 第三部分：全局描述符表 (GDT)
# =============================================================================
# GDT 定义了保护模式下的内存段
# 本引导程序使用简单的平坦内存模型：代码段和数据段都覆盖整个 4GB 地址空间
# =============================================================================
# Bootstrap GDT
.p2align 2                                # 4 字节对齐
gdt:
  SEG_NULLASM                             # 空段（第 0 项必须为空）
  SEG_ASM(STA_X|STA_R, 0x0, 0xffffffff)   # 代码段：可执行+可读，基址0，界限4GB
  SEG_ASM(STA_W, 0x0, 0xffffffff)         # 数据段：可写，基址0，界限4GB

# GDT 描述符：包含 GDT 的大小和地址，供 lgdt 指令使用
gdtdesc:
  .word   (gdtdesc - gdt - 1)             # GDT 大小 - 1（以字节为单位）
  .long   gdt                             # GDT 的起始地址

