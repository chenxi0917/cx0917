// =============================================================================
// xv6 引导加载程序 C 代码 (bootmain.c)
// =============================================================================
//
// 【启动流程概述】
// 这是 xv6 启动的第二阶段。bootasm.S 完成实模式到保护模式的切换后，
// 调用本文件的 bootmain() 函数来加载内核。
//
// 【主要任务】
// 1. 从硬盘读取内核的 ELF 文件头
// 2. 解析 ELF 头，找到各个程序段（segment）
// 3. 将内核的各个段加载到内存中
// 4. 跳转到内核入口点（entry.S 中的 entry）开始执行内核
//
// 【启动链路】
// BIOS -> bootasm.S -> bootmain.c (本文件) -> entry.S -> main.c
// =============================================================================

// Boot loader.
//
// Part of the boot block, along with bootasm.S, which calls bootmain().
// bootasm.S has put the processor into protected 32-bit mode.
// bootmain() loads an ELF kernel image from the disk starting at
// sector 1 and then jumps to the kernel entry routine.

#include "types.h"
#include "elf.h"
#include "x86.h"
#include "memlayout.h"

#define SECTSIZE  512   // 磁盘扇区大小：512 字节

void readseg(uchar*, uint, uint);

// =============================================================================
// 【VGA 文本模式输出函数】
// 在引导阶段，还没有初始化控制台，所以直接写 VGA 显存来显示启动信息
// VGA 文本模式显存起始地址：0xB8000
// 每个字符占 2 字节：低字节是 ASCII 码，高字节是颜色属性
// =============================================================================
static int boot_cursor = 0;  // 当前光标位置

// 在屏幕上打印一个字符
static void
boot_putc(int c)
{
  volatile ushort *vga = (volatile ushort*)0xB8000;
  
  if(c == '\n') {
    // 换行：移动到下一行开头
    boot_cursor = (boot_cursor / 80 + 1) * 80;
  } else {
    // 打印字符：白色前景(0x0F) + 黑色背景(0x00) = 0x0F
    vga[boot_cursor++] = (0x0F << 8) | (c & 0xFF);
  }
}

// 打印字符串
static void
boot_puts(const char *s)
{
  while(*s)
    boot_putc(*s++);
}

// =============================================================================
// 【bootmain - 引导加载程序主函数】
// 从硬盘加载 ELF 格式的内核镜像到内存，然后跳转执行
// =============================================================================
void
bootmain(void)
{
  struct elfhdr *elf;         // ELF 文件头指针
  struct proghdr *ph, *eph;   // 程序头指针
  void (*entry)(void);        // 内核入口函数指针
  uchar* pa;                  // 物理地址

  // -------------------------------------------------------------------------
  // 【打印启动信息】进入 bootmain
  // -------------------------------------------------------------------------
  boot_puts("[BOOT] enter bootmain\n");

  // -------------------------------------------------------------------------
  // 【读取 ELF 文件头】
  // 将 0x10000 作为临时缓冲区，读取内核镜像的第一页（4KB）
  // ELF 头位于文件开头，包含了整个可执行文件的结构信息
  // -------------------------------------------------------------------------
  elf = (struct elfhdr*)0x10000;  // scratch space  临时缓冲区

  // Read 1st page off disk  从磁盘读取第一页
  readseg((uchar*)elf, 4096, 0);

  // -------------------------------------------------------------------------
  // 【验证 ELF 魔数】
  // ELF 文件的前 4 个字节是魔数：0x7F, 'E', 'L', 'F'
  // 如果魔数不匹配，说明不是有效的 ELF 文件，返回让 bootasm.S 处理错误
  // -------------------------------------------------------------------------
  // Is this an ELF executable?  检查是否为 ELF 可执行文件
  if(elf->magic != ELF_MAGIC)
    return;  // let bootasm.S handle error  不是 ELF 文件，返回

  // -------------------------------------------------------------------------
  // 【打印启动信息】ELF 头加载成功
  // -------------------------------------------------------------------------
  boot_puts("[BOOT] elf header loaded\n");

  // -------------------------------------------------------------------------
  // 【加载内核各程序段】
  // ELF 文件包含多个程序段（如 .text 代码段、.data 数据段）
  // 程序头表描述了每个段应该加载到哪个物理地址、段的大小等信息
  // -------------------------------------------------------------------------
  // Load each program segment (ignores ph flags).
  // 遍历并加载每个程序段（忽略段标志）
  ph = (struct proghdr*)((uchar*)elf + elf->phoff);  // 程序头表起始位置
  eph = ph + elf->phnum;                              // 程序头表结束位置
  for(; ph < eph; ph++){
    pa = (uchar*)ph->paddr;                           // 段的物理加载地址
    readseg(pa, ph->filesz, ph->off);                 // 从磁盘读取段内容
    // 如果内存大小 > 文件大小，用 0 填充剩余部分（如 .bss 段）
    if(ph->memsz > ph->filesz)
      stosb(pa + ph->filesz, 0, ph->memsz - ph->filesz);
  }

  // -------------------------------------------------------------------------
  // 【打印启动信息】内核加载完成
  // -------------------------------------------------------------------------
  boot_puts("[BOOT] kernel loaded\n");

  // -------------------------------------------------------------------------
  // 【跳转到内核入口】
  // ELF 头中的 entry 字段指定了程序入口点地址
  // 对于 xv6 内核，入口点是 entry.S 中的 _start 符号
  // 这个 call 不会返回！
  // -------------------------------------------------------------------------
  // Call the entry point from the ELF header.
  // Does not return!  调用 ELF 头中指定的入口点（不会返回）
  entry = (void(*)(void))(elf->entry);
  entry();    // 跳转到内核！-> entry.S
}

// =============================================================================
// 【waitdisk - 等待磁盘就绪】
// 通过轮询 IDE 控制器状态寄存器等待磁盘准备好
// 端口 0x1F7 是主 IDE 控制器的状态/命令寄存器
// =============================================================================
void
waitdisk(void)
{
  // Wait for disk ready.  等待磁盘就绪
  // 状态位：bit7=BUSY, bit6=DRDY  等待 BUSY=0, DRDY=1 (即 0x40)
  while((inb(0x1F7) & 0xC0) != 0x40)
    ;
}

// =============================================================================
// 【readsect - 读取单个扇区】
// 使用 PIO 模式从 IDE 硬盘读取一个扇区（512字节）到指定内存地址
// =============================================================================
// Read a single sector at offset into dst.
// 读取偏移量 offset 处的单个扇区到 dst
void
readsect(void *dst, uint offset)
{
  // Issue command.  发送读取命令
  waitdisk();
  outb(0x1F2, 1);                     // 扇区数 = 1
  outb(0x1F3, offset);                // LBA 地址低 8 位
  outb(0x1F4, offset >> 8);           // LBA 地址 8-15 位
  outb(0x1F5, offset >> 16);          // LBA 地址 16-23 位
  outb(0x1F6, (offset >> 24) | 0xE0); // LBA 地址 24-27 位 + 主盘 + LBA模式
  outb(0x1F7, 0x20);                  // 命令 0x20 = 读扇区

  // Read data.  读取数据
  waitdisk();
  // 从数据端口 0x1F0 读取 128 个双字（512 字节）
  insl(0x1F0, dst, SECTSIZE/4);
}

// =============================================================================
// 【readseg - 读取任意长度数据】
// 从内核镜像的 offset 字节处读取 count 字节到物理地址 pa
// 由于磁盘按扇区读取，可能会多读一些数据，但不影响正确性
// =============================================================================
// Read 'count' bytes at 'offset' from kernel into physical address 'pa'.
// Might copy more than asked.
// 从内核镜像读取 count 字节到物理地址 pa，可能多读一些
void
readseg(uchar* pa, uint count, uint offset)
{
  uchar* epa;

  epa = pa + count;   // 结束地址

  // Round down to sector boundary.  对齐到扇区边界
  pa -= offset % SECTSIZE;

  // Translate from bytes to sectors; kernel starts at sector 1.
  // 将字节偏移转换为扇区号；内核从第 1 扇区开始（第 0 扇区是引导扇区）
  offset = (offset / SECTSIZE) + 1;

  // If this is too slow, we could read lots of sectors at a time.
  // We'd write more to memory than asked, but it doesn't matter --
  // we load in increasing order.
  // 逐扇区读取（可以优化为批量读取，但这里简单处理）
  for(; pa < epa; pa += SECTSIZE, offset++)
    readsect(pa, offset);
}
