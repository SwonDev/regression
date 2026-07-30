#ifndef TEST_GS
#define TEST_GS 0
#endif

    .section .rodata
passed_message:
    .ascii "FEX_SEGMENT_SELECTOR_ROUNDTRIP_OK\n"
    .set passed_message_length, . - passed_message
failed_message:
    .ascii "FEX_SEGMENT_SELECTOR_ROUNDTRIP_FAILED\n"
    .set failed_message_length, . - failed_message

    .section .data
    .align 4
ldt_entry:
    .long 0
    .long 0
    .long 0xfffff
    .long 0x51

    .section .text
    .global _start
_start:
    mov $154, %eax
    mov $1, %edi
    lea ldt_entry(%rip), %rsi
    mov $16, %edx
    syscall
    test %rax, %rax
    js selector_failed

#if TEST_GS
    mov $7, %eax
    movw %ax, %gs
    xor %eax, %eax
    movw %gs, %ax
#else
    mov $7, %eax
    movw %ax, %fs
    xor %eax, %eax
    movw %fs, %ax
#endif
    cmpw $7, %ax
    jne selector_failed

    mov $1, %eax
    mov $1, %edi
    lea passed_message(%rip), %rsi
    mov $passed_message_length, %edx
    syscall

    xor %edi, %edi
    mov $60, %eax
    syscall

selector_failed:
    mov $1, %eax
    mov $2, %edi
    lea failed_message(%rip), %rsi
    mov $failed_message_length, %edx
    syscall

    mov $1, %edi
    mov $60, %eax
    syscall
