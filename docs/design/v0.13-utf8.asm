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
; utf8.asm (skip, SKIP_SCALAR, VALID_SCALAR) and emit_simd_find_json; seek
; (validate the prefix + skip in one pass, AVX2) was added later. Changes:
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
; find_json_hi at 0, 1 and 2). kh_utf8_seek: 594,181,761 checks against
; ref_skip + ref_scan of the prefix, 0 mismatches (random buffers of 0-299
; bytes at a page end / page start / mid-page with every k or a sample of k;
; every 1- and 2-byte sequence at offsets 0, 1, 29-33, 61-63 on an ASCII and a
; Cyrillic background; every 3-byte sequence at offsets 0, 30, 31, 32).
; kh_case (added with seek): 77,682,688 checks against a per-character
; reference (random mixes of ASCII, Cyrillic and other characters at a page end /
; page start / mid-page, both modes, write and check; every byte pair at every
; position of 33- and 66-byte buffers on three backgrounds): output, stop
; position on a character boundary, nothing written past it but the lead of a
; pair across the boundary, no early stop.
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

align 32
global CASET
; per mode 128 bytes: [0] lo (first letter to change), [32] TD (continuation
; deltas: index 8..B after D0, 0..3 after D1), [64] TL (lead deltas: index 8..B
; for D0, 0..3 for D1, by the high nibble of the next byte), [96] unused;
; [256] 25 (letters lo..lo+25), [288] 0x0F, [320] 0xC0, [352] 0xA0, [384] 0xD0,
; [416] 0xD1, [448] 0x20 (khc puts this 480-byte table 32-aligned into DATA:
; case_consts)
CASET:
; lower
times 32 db 0x41
times 2 db 0,0,0,0, 0,0,0,0, 0x10,0x20,0xE0,0, 0,0,0,0
times 2 db 0,0,0,0, 0,0,0,0, 1,0,1,0, 0,0,0,0
times 32 db 0
; upper
times 32 db 0x61
times 2 db 0x20,0xF0,0,0, 0,0,0,0, 0,0,0,0xE0, 0,0,0,0
times 2 db 0xFF,0xFF,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0
times 32 db 0
KC25: times 32 db 25
KC0F: times 32 db 0x0F
KCC0: times 32 db 0xC0
KCA0: times 32 db 0xA0
KCD0: times 32 db 0xD0
KCD1: times 32 db 0xD1
KC20: times 32 db 0x20

section .text
global kh_utf8_scan, kh_utf8_skip, kh_utf8_seek, kh_find_json_hi, kh_case

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

; BLOCK without counting (for kh_utf8_seek): ymm0 = block, ymm6 = previous block,
; ymm7 |= errors, ymm8 = "previous block ended inside a character"; with %1 = 1
; (the last block) the table errors count only where ymm9 = FF, and the state
; for a next block is not kept
%macro VBLOCK 1
    vpmovmskb ecx, ymm0
    test ecx, ecx
    jnz %%full
    vpor ymm7, ymm7, ymm8       ; ASCII block right after an unfinished character
%if %1 == 0
    vpxor xmm8, xmm8, xmm8
    vmovdqa ymm6, ymm0
%endif
    jmp %%done
%%full:
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
%if %1 == 1
    vpand ymm2, ymm2, ymm9
    vpor ymm7, ymm7, ymm2
%else
    vpor ymm7, ymm7, ymm2
    vpsubusb ymm8, ymm0, [MAXV]
    vmovdqa ymm6, ymm0
%endif
%%done:
%endmacro

; one block of kh_case: ymm0 = c (the bytes at rax), a = the bytes before them,
; z = the bytes after them: loaded from rax + 1 (%1 = 0) or c shifted by one
; byte with a zero after the end (%1 = 1, the last block)
%macro CBLOCK 1
    vpmovmskb ecx, ymm0
    test ecx, ecx
    jnz %%full
    ; ASCII: only letters
    vpsubb ymm1, ymm0, [r8]
    vpminub ymm3, ymm1, [KC25]
    vpcmpeqb ymm3, ymm3, ymm1
    test rdi, rdi
    jnz %%aw
    vptest ymm3, ymm3
    jnz .out
    jmp %%done
%%aw:
    vpand ymm3, ymm3, ymm8
    vpxor ymm2, ymm0, ymm3
    vmovdqu [rdi+rax], ymm2
    jmp %%done
%%full:
    ; a = the bytes before c (a zero before the first one)
    test rax, rax
    jnz %%aload
    vperm2i128 ymm1, ymm0, ymm0, 0x08
    vpalignr ymm2, ymm0, ymm1, 15
    jmp %%ahave
%%aload:
    vmovdqu ymm2, [rsi+rax-1]
%%ahave:
    vpcmpeqb ymm3, ymm2, ymm11           ; a = D1
    vpcmpeqb ymm4, ymm2, ymm12           ; a = D0
    vpsrlw ymm1, ymm0, 4
    vpand ymm1, ymm1, ymm15              ; high nibble of c
    vpand ymm2, ymm3, ymm8
    vpsrlw ymm2, ymm2, 2                 ; 8 after D1
    vpxor ymm1, ymm1, ymm2               ; index into TD
    vmovdqu ymm2, [r8+32]
    vpshufb ymm2, ymm2, ymm1
    vpor ymm1, ymm3, ymm4
    vpand ymm2, ymm2, ymm1               ; continuation deltas
    vpaddb ymm2, ymm2, ymm0              ; out = c + deltas
    vpcmpgtb ymm1, ymm13, ymm0           ; c in 80..9F
    vpand ymm3, ymm3, ymm1
    vpor ymm3, ymm3, ymm4                ; after D0, or after D1 and c <= 9F
    vpcmpgtb ymm1, ymm14, ymm0           ; c in 80..BF
    vpand ymm3, ymm3, ymm1               ; good continuation bytes
    vpmovmskb r9d, ymm3
%if %1 == 0
    vmovdqu ymm1, [rsi+rax+1]            ; z
%else
    vperm2i128 ymm1, ymm0, ymm0, 0x81
    vpalignr ymm1, ymm1, ymm0, 1         ; z, 0 after the end
%endif
    vpcmpeqb ymm4, ymm0, ymm12           ; c = D0
    vpcmpgtb ymm3, ymm14, ymm1           ; z in 80..BF
    vpand ymm3, ymm3, ymm4
    vpmovmskb r10d, ymm3
    or r9d, r10d
    vpcmpeqb ymm3, ymm0, ymm11           ; c = D1
    vpcmpgtb ymm6, ymm13, ymm1           ; z in 80..9F
    vpand ymm6, ymm6, ymm3
    vpmovmskb r10d, ymm6
    or r9d, r10d                         ; good bytes >= 0x80
    not r9d
    and ecx, r9d
    jnz .out                             ; anything else: by characters
    vpor ymm4, ymm4, ymm3                ; c = D0 or D1
    vpand ymm3, ymm3, ymm8
    vpsrlw ymm3, ymm3, 2                 ; 8 for D1
    vpsrlw ymm1, ymm1, 4
    vpand ymm1, ymm1, ymm15
    vpxor ymm1, ymm1, ymm3               ; index into TL
    vmovdqu ymm3, [r8+64]
    vpshufb ymm3, ymm3, ymm1
    vpand ymm3, ymm3, ymm4               ; lead deltas
    vpaddb ymm2, ymm2, ymm3
    vpsubb ymm1, ymm0, [r8]
    vpminub ymm3, ymm1, [KC25]
    vpcmpeqb ymm3, ymm3, ymm1
    vpand ymm3, ymm3, ymm8
    vpxor ymm2, ymm2, ymm3               ; ASCII letters
    test rdi, rdi
    jnz %%fw
    vpcmpeqb ymm1, ymm2, ymm0
    vpmovmskb ecx, ymm1
    not ecx
    test ecx, ecx
    jnz .out
    jmp %%done
%%fw:
    vmovdqu [rdi+rax], ymm2
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
    vmovdqu ymm5, [KC0F]
    vmovdqu ymm10, [KCC0]
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
.in:                            ; the k-th lead is in this block
    cmp byte [__simd_level], 3
    jb .clr0
    lea r8, [rdx-1]             ; level 3 (fast PDEP): bit k-1 deposited into the mask
    xor r9d, r9d                ; lands on the k-th lowest lead
    bts r9, r8
    pdep rcx, r9, rcx
    jmp .bit
.clr0:                          ; otherwise drop k-1 lowest bits one by one
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

; byte offset where lead-rule character k starts (k >= 0; n if there are <= k
; characters) if [p, p+offset) is well-formed (for offset n: all of [p, p+n)),
; else -1 - offset. One pass instead of scan + skip: blocks are validated only
; up to the block of character k, and there the table errors count only up to
; the offset byte inclusive (an error at that byte means the character before it
; is unfinished). AVX2 only: below level 2 the caller (lib/text.kh,
; __utf8_seek) uses skip and scan.
kh_utf8_seek:
    xor eax, eax
    test rdx, rdx
    jz .done
    push rbp
    mov rbp, rsp
    sub rsp, 64
    and rsp, -32
    vpxor xmm7, xmm7, xmm7
    vpxor xmm6, xmm6, xmm6
    vpxor xmm8, xmm8, xmm8
    vmovdqu ymm5, [KC0F]
    vmovdqu ymm10, [KCC0]
    vmovdqu ymm11, [T1]
    vmovdqu ymm12, [T2]
    vmovdqu ymm13, [T3]
    vmovdqu ymm14, [C60]
    vmovdqu ymm15, [C70]
    vmovdqu ymm4, [C80]
    mov r10d, 1                 ; byte 0 starts character 0 even if it is 10xxxxxx
.blk:
    lea rcx, [rax+32]
    cmp rcx, rsi
    ja .tail
    vmovdqu ymm0, [rdi+rax]
    vpcmpgtb ymm9, ymm10, ymm0  ; -64 > b (signed): b in 0x80..0xBF
    vpmovmskb ecx, ymm9
    not ecx
    or ecx, r10d                ; leads of the block
    xor r10d, r10d
    popcnt r9d, ecx
    cmp r9, rdx
    ja .found                   ; character k starts in this block
    sub rdx, r9
    VBLOCK 0
    add rax, 32
    jmp .blk
.tail:
    ; r = n - rax bytes (0..31), as in kh_utf8_scan, but r is in r11 (rdx = k)
    mov r11, rsi
    sub r11, rax
    lea r9, [rdi+rax]
    vpxor xmm0, xmm0, xmm0
    test r11, r11
    jz .tblk
    mov ecx, r9d
    and ecx, 4095
    cmp ecx, 4064
    ja .slowtail
    lea rcx, [MASKT+32]
    sub rcx, r11
    vmovdqu ymm0, [r9]
    vpand ymm0, ymm0, [rcx]
    jmp .tblk
.slowtail:
    vmovdqa [rsp], ymm0
    cmp r11, 16
    jb .t8
    vmovdqu xmm1, [r9]
    vmovdqu xmm2, [r9+r11-16]
    vmovdqu [rsp], xmm1
    vmovdqu [rsp+r11-16], xmm2
    jmp .tdo
.t8:
    cmp r11, 8
    jb .t4
    mov rcx, [r9]
    mov r8, [r9+r11-8]
    mov [rsp], rcx
    mov [rsp+r11-8], r8
    jmp .tdo
.t4:
    cmp r11, 4
    jb .t2
    mov ecx, [r9]
    mov r8d, [r9+r11-4]
    mov [rsp], ecx
    mov [rsp+r11-4], r8d
    jmp .tdo
.t2:
    cmp r11, 2
    jb .t1
    movzx ecx, word [r9]
    movzx r8d, word [r9+r11-2]
    mov [rsp], cx
    mov [rsp+r11-2], r8w
    jmp .tdo
.t1:
    movzx ecx, byte [r9]
    mov [rsp], cl
.tdo:
    vmovdqa ymm0, [rsp]
.tblk:
    ; leads among the r real bytes
    mov ecx, r11d
    mov r8d, 1
    shl r8d, cl
    dec r8d
    vpcmpgtb ymm9, ymm10, ymm0
    vpmovmskb ecx, ymm9
    not ecx
    or ecx, r10d
    and ecx, r8d
    popcnt r9d, ecx
    cmp r9, rdx
    ja .found
    ; no character k: offset n; check the real bytes and the first zero after
    ; them (it closes an unfinished character)
    mov rax, rsi
    lea r8d, [r11+1]
    jmp .last
.found:
    ; drop the rdx lowest leads; the next one starts character k (level 3:
    ; bit rdx deposited into the mask with PDEP lands on that lead)
    cmp byte [__simd_level], 3
    jb .clr0
    xor r8d, r8d
    bts r8, rdx
    pdep rcx, r8, rcx
    jmp .bit
.clr0:
    test rdx, rdx
    jz .bit
.clr:
    lea r8d, [rcx-1]
    and ecx, r8d
    dec rdx
    jnz .clr
.bit:
    bsf ecx, ecx
    add rax, rcx
    lea r8d, [rcx+1]
.last:
    ; the block in ymm0, table errors only in its first r8 bytes (1..32)
    lea rcx, [MASKT+32]
    sub rcx, r8
    vmovdqu ymm9, [rcx]
    VBLOCK 1
    vptest ymm7, ymm7
    vzeroupper
    mov rsp, rbp
    pop rbp
    jz .done
    not rax
.done:
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

; case mapping of ASCII and Cyrillic U+0400-045F in 32-byte blocks (lengths do
; not change, so every byte maps in place from itself and its neighbours):
; rdi = dst (0: only check that nothing changes), rsi = src, rdx = n, rcx = 1
; for upper case. Returns how many bytes from the start are done: a block with
; anything else (other leads, D1 A0-BF, lone continuation bytes, a lead without
; its continuation), or, with rdi = 0, a block where something changes, is not
; taken, and the answer is its start, or the lead before it when a pair crosses
; the block boundary (that lead is already written; the caller rewrites it).
; The last block overlaps up to n. n < 32: 0. AVX2 only.
kh_case:
    xor eax, eax
    cmp rdx, 32
    jb .ret
    shl ecx, 7
    lea r8, [rcx+CASET]
    vmovdqu ymm8, [KC20]
    vmovdqu ymm11, [KCD1]
    vmovdqu ymm12, [KCD0]
    vmovdqu ymm13, [KCA0]
    vmovdqu ymm14, [KCC0]
    vmovdqu ymm15, [KC0F]
.blk:
    mov r11, rax
    lea rcx, [rax+33]
    cmp rcx, rdx
    ja .last
    vmovdqu ymm0, [rsi+rax]
    CBLOCK 0
    add rax, 32
    jmp .blk
.last:
    cmp rax, rdx
    je .end
    mov rax, rdx
    sub rax, 32
    vmovdqu ymm0, [rsi+rax]
    CBLOCK 1
    mov rax, rdx
    jmp .end
.out:
    ; block not taken: a pair across its start goes by characters too
    mov rax, r11
    test rax, rax
    jz .end
    movzx ecx, byte [rsi+rax-1]
    and ecx, 0xFE
    cmp ecx, 0xD0
    jne .end
    dec rax
.end:
    vzeroupper
.ret:
    ret
