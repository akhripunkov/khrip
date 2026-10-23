; Khrip v0.13: the UTF-8 primitives exactly as src/simd.kh emits them (inline at
; the call site; the final ret of each function is not emitted, the code falls
; through instead). src/simd.kh carries these bytes from
;     nasm -f elf64 v0.13-utf8.asm && objdump -dr -M intel v0.13-utf8.o
; with the jumps inside each primitive as they are; the [disp32] operands (the
; relocations) are filled with DATA addresses by khc: __simd_level, and the
; 352-byte table UTAB, which khc puts 32-aligned into DATA (utf8_consts).
; To change a primitive, edit this file, re-assemble and copy the bytes again;
; tests/run/utf8_simd.kh checks the result at KHRIP_SIMD=0, 1 and 2.
;
; Sources (v0.13-utf8.md, section 4.1): scan3.asm (fused validate+count, AVX2),
; utf8.asm (skip, SKIP_SCALAR, VALID_SCALAR) and emit_simd_find_json. Changes:
;   - constants are loaded with vmovdqu [abs] (no RIP-relative addressing in khc);
;   - dispatch on __simd_level: 2 = AVX2, else the scalar/SWAR path
;     (find_json_hi keeps all three paths of find_json: AVX2, SSE2, bytewise);
;   - the scan fallback is VALID_SCALAR with counting in rax, -1 on error;
;   - find_json_hi = find_json + OR of the raw high-bit mask in r9d; the result
;     is index | (hi << 62).
; Verified with a C harness against reference functions: 271,925,030 checks,
; 0 mismatches (4M random buffers at a page end / page start / mid-page, every
; 3-byte value at offsets 0, 7, 14, 21, 28-39, F0-F4 x continuation x all x
; sampled 4-byte sequences at offsets 28-32; scan and skip at levels 0 and 2,
; find_json_hi at 0, 1 and 2).
; Calling convention: rdi = p, rsi = n, rdx = k; result in rax; clobbers only
; rax rcx rdx rsi rdi r8-r11 ymm0-ymm15 (rbp is pushed and restored); no calls.
default abs
section .data
global __simd_level
__simd_level: db 2

section .rodata
align 32
global UTAB
UTAB:
C0F: times 32 db 0x0F
CC0: times 32 db 0xC0
T1: times 2 db 2,2,2,2,2,2,2,2, 128,128,128,128, 33,1,21,73
T2: times 2 db 231,163,131,131,139,203,203,203,203,203,203,203,203,219,203,203
T3: times 2 db 1,1,1,1,1,1,1,1, 230,174,186,186, 1,1,1,1
C60: times 32 db 0x60
C70: times 32 db 0x70
C80: times 32 db 0x80
MASKT: times 32 db 0xFF
       times 32 db 0
MAXV: times 29 db 255
      db 0xEF, 0xDF, 0xBF

section .text
global kh_utf8_scan, kh_utf8_skip, kh_find_json_hi

%define H8 0x8080808080808080

; ymm0 = block, ymm6 = previous block; ymm7 |= errors; r8 += continuation count
%macro BLOCK 0
    vpmovmskb ecx, ymm0
    test ecx, ecx
    jnz %%full
    vpor ymm7, ymm7, ymm8       ; ASCII block right after an unfinished character
    vpxor xmm8, xmm8, xmm8
    vmovdqa ymm6, ymm0
    jmp %%done
%%full:
    vpcmpgtb ymm9, ymm10, ymm0          ; -64 > b (signed): b in 0x80..0xBF
    vpmovmskb ecx, ymm9
    popcnt ecx, ecx
    add r8, rcx
    vperm2i128 ymm1, ymm6, ymm0, 0x21
    vpalignr ymm2, ymm0, ymm1, 15        ; prev1
    vpsrlw ymm3, ymm2, 4
    vpand ymm3, ymm3, ymm5
    vpshufb ymm3, ymm11, ymm3            ; byte_1_high
    vpand ymm2, ymm2, ymm5
    vpshufb ymm2, ymm12, ymm2            ; byte_1_low
    vpand ymm3, ymm3, ymm2
    vpsrlw ymm2, ymm0, 4
    vpand ymm2, ymm2, ymm5
    vpshufb ymm2, ymm13, ymm2            ; byte_2_high
    vpand ymm3, ymm3, ymm2
    vpalignr ymm2, ymm0, ymm1, 14        ; prev2
    vpalignr ymm1, ymm0, ymm1, 13        ; prev3
    vpsubusb ymm2, ymm2, ymm14           ; prev2 >= 0xE0 -> bit 7
    vpsubusb ymm1, ymm1, ymm15           ; prev3 >= 0xF0 -> bit 7
    vpor ymm2, ymm2, ymm1
    vpand ymm2, ymm2, ymm4               ; keep bit 7
    vpxor ymm2, ymm2, ymm3
    vpor ymm7, ymm7, ymm2
    ; "this block ends inside a character": last byte >= C0, or 2nd-last >= E0, or 3rd-last >= F0
    vpsubusb ymm8, ymm0, [MAXV]
    vmovdqa ymm6, ymm0
%%done:
%endmacro

; strict scalar validation of [rcx, rsi) with counting in rax: jumps to %1 (bad)
; or falls through (good)
%macro VALID_COUNT 1
%%s:
    cmp rcx, rsi
    jae %%good
    lea r8, [rcx+8]
    cmp r8, rsi
    ja %%one
    mov r8, [rdi+rcx]
    mov r9, H8
    test r8, r9
    jnz %%one
    add rcx, 8                  ; 8 ASCII bytes at once
    add rax, 8
    jmp %%s
%%one:
    inc rax
    movzx edx, byte [rdi+rcx]
    cmp edx, 0x80
    jb %%a1
    cmp edx, 0xC2
    jb %1
    cmp edx, 0xE0
    jb %%c2
    cmp edx, 0xF0
    jb %%c3
    cmp edx, 0xF4
    ja %1
    lea r8, [rcx+3]
    cmp r8, rsi
    jae %1
    movzx r9d, byte [rdi+rcx+1]
    cmp edx, 0xF0
    jne %%f1
    cmp r9d, 0x90
    jb %1
%%f1:
    cmp edx, 0xF4
    jne %%f2
    cmp r9d, 0x8F
    ja %1
%%f2:
    and r9d, 0xC0
    cmp r9d, 0x80
    jne %1
    movzx r9d, byte [rdi+rcx+2]
    and r9d, 0xC0
    cmp r9d, 0x80
    jne %1
    movzx r9d, byte [rdi+rcx+3]
    and r9d, 0xC0
    cmp r9d, 0x80
    jne %1
    add rcx, 4
    jmp %%s
%%c3:
    lea r8, [rcx+2]
    cmp r8, rsi
    jae %1
    movzx r9d, byte [rdi+rcx+1]
    cmp edx, 0xE0
    jne %%e1
    cmp r9d, 0xA0
    jb %1
%%e1:
    cmp edx, 0xED
    jne %%e2
    cmp r9d, 0x9F
    ja %1
%%e2:
    and r9d, 0xC0
    cmp r9d, 0x80
    jne %1
    movzx r9d, byte [rdi+rcx+2]
    and r9d, 0xC0
    cmp r9d, 0x80
    jne %1
    add rcx, 3
    jmp %%s
%%c2:
    lea r8, [rcx+1]
    cmp r8, rsi
    jae %1
    movzx r9d, byte [rdi+rcx+1]
    and r9d, 0xC0
    cmp r9d, 0x80
    jne %1
    add rcx, 2
    jmp %%s
%%a1:
    inc rcx
    jmp %%s
%%good:
%endmacro

; number of code points if [p, p+n) is well-formed, else -1
kh_utf8_scan:
    cmp byte [__simd_level], 2
    jb .swar
    push rbp
    mov rbp, rsp
    sub rsp, 64
    and rsp, -32
    xor eax, eax                ; block offset
    xor r8d, r8d                ; continuation bytes
    vpxor xmm7, xmm7, xmm7
    vpxor xmm6, xmm6, xmm6
    vpxor xmm8, xmm8, xmm8
    vmovdqu ymm5, [C0F]
    vmovdqu ymm10, [CC0]
    vmovdqu ymm11, [T1]
    vmovdqu ymm12, [T2]
    vmovdqu ymm13, [T3]
    vmovdqu ymm14, [C60]
    vmovdqu ymm15, [C70]
    vmovdqu ymm4, [C80]
.blk:
    lea rcx, [rax+32]
    cmp rcx, rsi
    ja .tail
    vmovdqu ymm0, [rdi+rax]
    BLOCK
    add rax, 32
    jmp .blk
.tail:
    ; r = n - rax bytes (0..31): one 32-byte load when it stays inside the page,
    ; masked to r bytes; near the end of a page, a zeroed stack block instead
    mov rdx, rsi
    sub rdx, rax
    lea r9, [rdi+rax]           ; source of the tail
    vpxor xmm0, xmm0, xmm0
    test rdx, rdx
    jz .tblk                    ; nothing left: a zero block closes an unfinished character
    mov ecx, r9d
    and ecx, 4095
    cmp ecx, 4064
    ja .slowtail
    lea rcx, [MASKT+32]
    sub rcx, rdx
    vmovdqu ymm0, [r9]
    vpand ymm0, ymm0, [rcx]
    jmp .tblk
.slowtail:
    vmovdqa [rsp], ymm0
    cmp rdx, 16
    jb .t8
    vmovdqu xmm1, [r9]
    vmovdqu xmm2, [r9+rdx-16]
    vmovdqu [rsp], xmm1
    vmovdqu [rsp+rdx-16], xmm2
    jmp .tdo
.t8:
    cmp rdx, 8
    jb .t4
    mov rcx, [r9]
    mov r10, [r9+rdx-8]
    mov [rsp], rcx
    mov [rsp+rdx-8], r10
    jmp .tdo
.t4:
    cmp rdx, 4
    jb .t2
    mov ecx, [r9]
    mov r10d, [r9+rdx-4]
    mov [rsp], ecx
    mov [rsp+rdx-4], r10d
    jmp .tdo
.t2:
    cmp rdx, 2
    jb .t1
    movzx ecx, word [r9]
    movzx r10d, word [r9+rdx-2]
    mov [rsp], cx
    mov [rsp+rdx-2], r10w
    jmp .tdo
.t1:
    movzx ecx, byte [r9]
    mov [rsp], cl
.tdo:
    vmovdqa ymm0, [rsp]
.tblk:
    BLOCK
    vptest ymm7, ymm7
    vzeroupper
    mov rsp, rbp
    pop rbp
    jnz .bad
    mov rax, rsi
    sub rax, r8
    jmp .done
.swar:
    xor ecx, ecx
    xor eax, eax
    VALID_COUNT .bad
    jmp .done
.bad:
    mov rax, -1
.done:
    ret

; byte offset where lead-rule character k starts (k >= 0); n if there are <= k characters
kh_utf8_skip:
    xor eax, eax
    test rdx, rdx
    jz .r
    mov eax, 1                  ; character 0 starts at 0: leads are searched in [1, n)
    cmp byte [__simd_level], 2
    jb .s
    mov ecx, 0xBFBFBFBF         ; -65: (v > -65) <=> v is not 10xxxxxx
    vmovd xmm1, ecx
    vpbroadcastd ymm1, xmm1
.blk:
    lea rcx, [rax+32]
    cmp rcx, rsi
    ja .t
    vmovdqu ymm0, [rdi+rax]
    vpcmpgtb ymm0, ymm0, ymm1
    vpmovmskb ecx, ymm0
    popcnt r9d, ecx
    cmp r9, rdx
    jae .in
    sub rdx, r9
    add rax, 32
    jmp .blk
.in:                            ; the k-th lead is in this block: drop k-1 lowest bits
    dec rdx
    jz .bit
.clr:
    lea r8d, [rcx-1]
    and ecx, r8d
    dec rdx
    jnz .clr
.bit:
    bsf ecx, ecx
    add rax, rcx
    vzeroupper
    jmp .r
.t:
    vzeroupper
.s:
    cmp rax, rsi
    jae .end
    movzx ecx, byte [rdi+rax]
    and ecx, 0xC0
    cmp ecx, 0x80
    je .n
    dec rdx
    jz .r
.n:
    inc rax
    jmp .s
.end:
    mov rax, rsi
.r:
    ret

; first '"', '\\' or byte < 0x20 (or n) | (any byte >= 0x80 before it) << 62
kh_find_json_hi:
    xor r9d, r9d                ; high bits seen
    xor eax, eax
    cmp byte [__simd_level], 1
    jb .sc
    cmp byte [__simd_level], 2
    jb .sse
    mov ecx, 0x22
    vmovd xmm1, ecx
    vpbroadcastb ymm1, xmm1
    mov ecx, 0x5C
    vmovd xmm2, ecx
    vpbroadcastb ymm2, xmm2
    mov ecx, 0x1F
    vmovd xmm3, ecx
    vpbroadcastb ymm3, xmm3
.atop:
    lea rcx, [rax+32]
    cmp rcx, rsi
    ja .aend
    vmovdqu ymm0, [rdi+rax]
    vpminub ymm6, ymm0, ymm3
    vpcmpeqb ymm6, ymm6, ymm0
    vpcmpeqb ymm5, ymm0, ymm1
    vpor ymm5, ymm5, ymm6
    vpcmpeqb ymm6, ymm0, ymm2
    vpor ymm5, ymm5, ymm6
    vpmovmskb ecx, ymm5
    vpmovmskb r8d, ymm0
    test ecx, ecx
    jnz .ahit
    or r9d, r8d
    add rax, 32
    jmp .atop
.ahit:
    lea r10, [rcx-1]
    xor r10, rcx
    and r8d, r10d
    or r9d, r8d
    vzeroupper
    jmp .found
.aend:
    vzeroupper
.sse:
    mov ecx, 0x22
    movd xmm1, ecx
    punpcklbw xmm1, xmm1
    punpcklwd xmm1, xmm1
    pshufd xmm1, xmm1, 0
    mov ecx, 0x5C
    movd xmm2, ecx
    punpcklbw xmm2, xmm2
    punpcklwd xmm2, xmm2
    pshufd xmm2, xmm2, 0
    mov ecx, 0x1F
    movd xmm3, ecx
    punpcklbw xmm3, xmm3
    punpcklwd xmm3, xmm3
    pshufd xmm3, xmm3, 0
.stop:
    lea rcx, [rax+16]
    cmp rcx, rsi
    ja .sc
    movdqu xmm0, [rdi+rax]
    movdqa xmm6, xmm0
    pminub xmm6, xmm3
    pcmpeqb xmm6, xmm0
    movdqa xmm5, xmm0
    pcmpeqb xmm5, xmm1
    por xmm5, xmm6
    movdqa xmm6, xmm0
    pcmpeqb xmm6, xmm2
    por xmm5, xmm6
    pmovmskb ecx, xmm5
    pmovmskb r8d, xmm0
    test ecx, ecx
    jnz .shit
    or r9d, r8d
    add rax, 16
    jmp .stop
.shit:
    lea r10, [rcx-1]
    xor r10, rcx
    and r8d, r10d
    or r9d, r8d
.found:
    bsf ecx, ecx
    add rax, rcx
    jmp .done
.sc:
    cmp rax, rsi
    jae .done
    movzx ecx, byte [rdi+rax]
    cmp ecx, 0x22
    je .done
    cmp ecx, 0x5C
    je .done
    cmp ecx, 0x20
    jb .done
    mov r10d, ecx
    shr r10d, 7
    or r9d, r10d
    inc rax
    jmp .sc
.done:
    test r9d, r9d
    jz .ret
    bts rax, 62
.ret:
    ret
