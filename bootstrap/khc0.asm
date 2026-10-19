; ============================================================================
; khc0 — зерно раскрутки компилятора Khrip.
;
; Понимает только подмножество Khrip-0 (docs/KHRIP0.md) и нужно ровно для одного:
; один раз собрать компилятор src/khc.kh. Дальше khc собирает сам себя.
;
; Устройство повторяет src/khc.kh: лексер разбивает весь текст на токены,
; затем рекурсивный спуск сразу генерирует машинный код x86-64 (стековая
; машина: результат выражения в rax, промежуточные значения в стеке).
; На выходе статический ELF без libc: код по адресу 0x400000, данные
; (строки и глобальные переменные) по адресу 0x10000000.
;
; Сборка: nasm -f elf64 khc0.asm -o khc0.o && ld khc0.o -o khc0
; Запуск: khc0 -o <выход> <вход.kh>...
; ============================================================================
BITS 64
DEFAULT REL

%define SYS_READ   0
%define SYS_WRITE  1
%define SYS_OPEN   2
%define SYS_CLOSE  3
%define SYS_EXIT   60

%define SRC_MAX   (8 << 20)
%define TOK_MAX   (1 << 20)
%define TOK_SIZE  40
%define CODE_MAX  (16 << 20)
%define DATA_MAX  (8 << 20)
%define SYM_MAX   (1 << 16)
%define SYM_SIZE  40
%define LOC_MAX   4096
%define LOC_SIZE  24
%define FIX_MAX   (1 << 20)
%define FIX_SIZE  32
%define BRK_MAX   4096

%define CODE_BASE 0x400000
%define HDR_SIZE  176
%define DATA_BASE 0x10000000

; Виды токенов. Одиночные знаки препинания кодируются своим ASCII-кодом.
%define T_EOF      0
%define T_IDENT    1
%define T_INT      2
%define T_STR      3
%define T_FN       10
%define T_LET      11
%define T_VAR      12
%define T_CONST    13
%define T_IF       14
%define T_ELSE     15
%define T_WHILE    16
%define T_RETURN   17
%define T_BREAK    18
%define T_CONTINUE 19
%define T_EQ       256
%define T_NE       257
%define T_LE       258
%define T_GE       259
%define T_ANDAND   260
%define T_OROR     261
%define T_SHL      262
%define T_SHR      263
%define T_ARROW    264

; Поля токена
%define TK_KIND 0
%define TK_VAL  8
%define TK_PTR  16
%define TK_LEN  24
%define TK_LINE 32

; Глобальные символы
%define S_CONST 1
%define S_VAR   2
%define S_FN    3
%define SY_PTR   0
%define SY_LEN   8
%define SY_KIND  16
%define SY_VAL   24      ; значение константы, адрес переменной, смещение функции (-1 — ещё не определена)
%define SY_EXTRA 32      ; число параметров функции

; Локальные переменные
%define LO_PTR 0
%define LO_LEN 8
%define LO_OFF 16        ; смещение относительно rbp

; Ссылки на функции, которые нужно дописать в конце
%define FX_POS  0
%define FX_SYM  8
%define FX_ARGC 16
%define FX_LINE 24

; Последовательность байтов машинного кода: байт длины, затем сами байты.
%macro DEFSEQ 2+
%1: db %%e - %%s
%%s: db %2
%%e:
%endmacro

%macro EMIT 1
    lea rsi, [%1]
    call emit_seq
%endmacro

%macro EXIT 1
    mov edi, %1
    mov eax, SYS_EXIT
    syscall
%endmacro

section .rodata

; Точка входа: main(argc, argv), код возврата main — код выхода процесса.
DEFSEQ s_start,       0x48,0x8B,0x04,0x24, 0x48,0x8D,0x4C,0x24,0x08, 0x50, 0x51   ; mov rax,[rsp]; lea rcx,[rsp+8]; push rax; push rcx
DEFSEQ s_exit,        0x48,0x89,0xC7, 0xB8,0x3C,0,0,0, 0x0F,0x05                  ; mov rdi,rax; mov eax,60; syscall
DEFSEQ s_prologue,    0x55, 0x48,0x89,0xE5, 0x48,0x81,0xEC                        ; push rbp; mov rbp,rsp; sub rsp,imm32
DEFSEQ s_ret0,        0x31,0xC0                                                   ; xor eax,eax
DEFSEQ s_epilogue,    0x48,0x89,0xEC, 0x5D, 0xC3                                  ; mov rsp,rbp; pop rbp; ret
DEFSEQ s_push_rax,    0x50
DEFSEQ s_pop_swap,    0x48,0x89,0xC1, 0x58                                        ; mov rcx,rax; pop rax
DEFSEQ s_add,         0x48,0x01,0xC8
DEFSEQ s_sub,         0x48,0x29,0xC8
DEFSEQ s_or,          0x48,0x09,0xC8
DEFSEQ s_xor,         0x48,0x31,0xC8
DEFSEQ s_and,         0x48,0x21,0xC8
DEFSEQ s_mul,         0x48,0x0F,0xAF,0xC1
DEFSEQ s_div,         0x48,0x99, 0x48,0xF7,0xF9                                   ; cqo; idiv rcx
DEFSEQ s_mod,         0x48,0x99, 0x48,0xF7,0xF9, 0x48,0x89,0xD0                   ; ...; mov rax,rdx
DEFSEQ s_shl,         0x48,0xD3,0xE0
DEFSEQ s_shr,         0x48,0xD3,0xF8                                              ; sar rax,cl
DEFSEQ s_cmp,         0x48,0x39,0xC8, 0x0F                                        ; cmp rax,rcx; setcc...
DEFSEQ s_setcc_tail,  0xC0, 0x0F,0xB6,0xC0                                        ; ...al; movzx eax,al
DEFSEQ s_neg,         0x48,0xF7,0xD8
DEFSEQ s_bnot,        0x48,0xF7,0xD0
DEFSEQ s_lnot,        0x48,0x85,0xC0, 0x0F,0x94,0xC0, 0x0F,0xB6,0xC0
DEFSEQ s_bool,        0x48,0x85,0xC0, 0x0F,0x95,0xC0, 0x0F,0xB6,0xC0
DEFSEQ s_test,        0x48,0x85,0xC0
DEFSEQ s_jz,          0x0F,0x84
DEFSEQ s_jnz,         0x0F,0x85
DEFSEQ s_jmp,         0xE9
DEFSEQ s_call,        0xE8
DEFSEQ s_mov_rax_imm, 0x48,0xB8
DEFSEQ s_load_local,  0x48,0x8B,0x85                                              ; mov rax,[rbp+disp32]
DEFSEQ s_store_local, 0x48,0x89,0x85                                              ; mov [rbp+disp32],rax
DEFSEQ s_deref,       0x48,0x8B,0x00                                              ; mov rax,[rax]
DEFSEQ s_mov_rcx_imm, 0x48,0xB9
DEFSEQ s_store_rcx,   0x48,0x89,0x01                                              ; mov [rcx],rax
DEFSEQ s_add_rsp,     0x48,0x81,0xC4
DEFSEQ s_load8,       0x58, 0x0F,0xB6,0x00                                        ; pop rax; movzx eax,byte [rax]
DEFSEQ s_load64,      0x58, 0x48,0x8B,0x00
DEFSEQ s_store8,      0x59, 0x58, 0x88,0x08                                       ; pop rcx; pop rax; mov [rax],cl
DEFSEQ s_store64,     0x59, 0x58, 0x48,0x89,0x08
DEFSEQ s_syscall,     0x0F,0x05
DEFSEQ s_pop0,        0x58          ; rax
DEFSEQ s_pop1,        0x5F          ; rdi
DEFSEQ s_pop2,        0x5E          ; rsi
DEFSEQ s_pop3,        0x5A          ; rdx
DEFSEQ s_pop4,        0x41,0x5A     ; r10
DEFSEQ s_pop5,        0x41,0x58     ; r8
DEFSEQ s_pop6,        0x41,0x59     ; r9

align 8
pop_table: dq s_pop0, s_pop1, s_pop2, s_pop3, s_pop4, s_pop5, s_pop6

kw_table:
    db 2, "fn", T_FN
    db 3, "let", T_LET
    db 3, "var", T_VAR
    db 5, "const", T_CONST
    db 2, "if", T_IF
    db 4, "else", T_ELSE
    db 5, "while", T_WHILE
    db 6, "return", T_RETURN
    db 5, "break", T_BREAK
    db 8, "continue", T_CONTINUE
    db 0

builtin_table:
    db 5, "load8", 1
    db 6, "load64", 2
    db 6, "store8", 3
    db 7, "store64", 4
    db 7, "syscall", 5
    db 0

two_table:
    db '=', '='
    dw T_EQ
    db '!', '='
    dw T_NE
    db '<', '='
    dw T_LE
    db '>', '='
    dw T_GE
    db '&', '&'
    dw T_ANDAND
    db '|', '|'
    dw T_OROR
    db '<', '<'
    dw T_SHL
    db '>', '>'
    dw T_SHR
    db '-', '>'
    dw T_ARROW
    db 0

single_chars: db "(){},:+-*/%&|^~!<>=", 0

str_main:        db "main"
msg_usage:       db "usage: khc0 -o <output> <input.kh>...", 10, 0
msg_prefix:      db "khc0: line ", 0
msg_colon:       db ": ", 0
msg_near:        db " (near '", 0
msg_near_end:    db "')", 10, 0
msg_quote:       db " '", 0
msg_quote_end:   db "'", 10, 0
msg_nl:          db 10, 0
msg_open:        db "khc0: cannot open input file", 10, 0
msg_src_big:     db "khc0: source too large", 10, 0
msg_out:         db "khc0: cannot write output file", 10, 0
msg_bad_char:    db "unexpected character", 0
msg_bad_escape:  db "bad escape sequence", 0
msg_bad_charlit: db "bad character literal", 0
msg_bad_str:     db "unterminated string", 0
msg_full:        db "compiler limit exceeded", 0
msg_exp_ident:   db "expected identifier", 0
msg_exp_expr:    db "expected expression", 0
msg_exp_int:     db "expected integer constant", 0
msg_top:         db "expected fn, var or const", 0
msg_dup:         db "duplicate definition", 0
msg_not_fn:      db "not a function", 0
msg_fn_value:    db "function used as a value", 0
msg_unknown:     db "unknown name", 0
msg_not_var:     db "cannot assign to this name", 0
msg_no_loop:     db "break or continue outside of a loop", 0
msg_builtin:     db "wrong number of arguments for builtin", 0
msg_undef:       db "undefined function", 0
msg_argc:        db "wrong number of arguments for", 0
msg_eof_block:   db "unexpected end of file inside a block", 0

section .data
msg_expected:    db "expected 'X'", 0

section .bss
src:         resb SRC_MAX
src_len:     resq 1
toks:        resb TOK_MAX * TOK_SIZE
ntok:        resq 1
pos:         resq 1
code:        resb CODE_MAX
code_len:    resq 1
data:        resb DATA_MAX
data_len:    resq 1
syms:        resb SYM_MAX * SYM_SIZE
nsyms:       resq 1
locs:        resb LOC_MAX * LOC_SIZE
nlocs:       resq 1
frame:       resq 1
fixes:       resb FIX_MAX * FIX_SIZE
nfix:        resq 1
brks:        resq BRK_MAX
nbrk:        resq 1
cont_target: resq 1
out_path:    resq 1
hdr:         resb HDR_SIZE
zeros:       resb 4096

section .text
global _start

; ----------------------------------------------------------------------------
; Точка входа: khc0 -o <выход> <вход>...
; ----------------------------------------------------------------------------
_start:
    mov rbx, [rsp]
    lea r12, [rsp+8]
    cmp rbx, 4
    jl usage
    mov rax, [r12+8]
    cmp byte [rax], '-'
    jne usage
    cmp byte [rax+1], 'o'
    jne usage
    cmp byte [rax+2], 0
    jne usage
    mov rax, [r12+16]
    mov [out_path], rax
    mov r13, 3
.read:
    cmp r13, rbx
    jge .compile
    mov rdi, [r12+r13*8]
    call read_file
    inc r13
    jmp .read
.compile:
    call lex
    call compile
    call write_elf
    EXIT 0

usage:
    lea rdi, [msg_usage]
    call print_err
    EXIT 2

; ----------------------------------------------------------------------------
; Вывод ошибок
; ----------------------------------------------------------------------------

; rdi = строка с нулём на конце → rax = длина
strlen:
    xor eax, eax
.l: cmp byte [rdi+rax], 0
    je .d
    inc rax
    jmp .l
.d: ret

; rdi = строка с нулём на конце → stderr
print_err:
    push rdi
    call strlen
    pop rsi
    mov rdx, rax
    jmp print_err_n

; rsi = указатель, rdx = длина → stderr
print_err_n:
    mov edi, 2
    mov eax, SYS_WRITE
    syscall
    ret

; rdi = неотрицательное число → stderr
print_num:
    sub rsp, 32
    lea rsi, [rsp+32]
    mov rax, rdi
    mov ecx, 10
.l: xor edx, edx
    div rcx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jnz .l
    lea rdx, [rsp+32]
    sub rdx, rsi
    call print_err_n
    add rsp, 32
    ret

; rdi = сообщение; ошибка у текущего токена
fatal:
    push rdi
    call tk_addr
    mov rsi, rax
    pop rdi
; rdi = сообщение, rsi = адрес токена
fatal_at:
    push rsi
    push rdi
    lea rdi, [msg_prefix]
    call print_err
    mov rax, [rsp+8]
    mov rdi, [rax+TK_LINE]
    call print_num
    lea rdi, [msg_colon]
    call print_err
    pop rdi
    call print_err
    lea rdi, [msg_near]
    call print_err
    pop rax
    mov rsi, [rax+TK_PTR]
    mov rdx, [rax+TK_LEN]
    call print_err_n
    lea rdi, [msg_near_end]
    call print_err
    EXIT 1

; rdi = сообщение, rsi = адрес символа, rdx = строка
fatal_sym:
    push rsi
    push rdi
    push rdx
    lea rdi, [msg_prefix]
    call print_err
    pop rdi
    call print_num
    lea rdi, [msg_colon]
    call print_err
    pop rdi
    call print_err
    lea rdi, [msg_quote]
    call print_err
    pop rax
    mov rsi, [rax+SY_PTR]
    mov rdx, [rax+SY_LEN]
    call print_err_n
    lea rdi, [msg_quote_end]
    call print_err
    EXIT 1

; rdi = сообщение; ошибка лексера, строка в r14
lex_fatal:
    push rdi
    lea rdi, [msg_prefix]
    call print_err
    mov rdi, r14
    call print_num
    lea rdi, [msg_colon]
    call print_err
    pop rdi
    call print_err
    lea rdi, [msg_nl]
    call print_err
    EXIT 1

limit_exceeded:
    lea rdi, [msg_full]
    jmp fatal

; ----------------------------------------------------------------------------
; Чтение исходников
; ----------------------------------------------------------------------------

; rdi = путь; содержимое дописывается в src, после файла — перевод строки
read_file:
    push rbx
    xor esi, esi
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .fail
    mov rbx, rax
.loop:
    mov rdi, rbx
    lea rsi, [src]
    add rsi, [src_len]
    mov rdx, SRC_MAX - 1
    sub rdx, [src_len]
    jle .too_big
    mov eax, SYS_READ
    syscall
    test rax, rax
    js .fail
    jz .done
    add [src_len], rax
    jmp .loop
.done:
    mov rdi, rbx
    mov eax, SYS_CLOSE
    syscall
    mov rax, [src_len]
    lea rcx, [src]
    mov byte [rcx+rax], 10
    inc qword [src_len]
    pop rbx
    ret
.fail:
    lea rdi, [msg_open]
    call print_err
    EXIT 1
.too_big:
    lea rdi, [msg_src_big]
    call print_err
    EXIT 1

; ----------------------------------------------------------------------------
; Лексер: весь текст → массив токенов
; Регистры: r12 — текущая позиция, r13 — конец, r14 — номер строки, rbx — начало токена
; ----------------------------------------------------------------------------

; rdi = вид, rsi = значение, rdx = начало, rcx = длина; строка в r14
add_tok:
    mov rax, [ntok]
    cmp rax, TOK_MAX
    jae .full
    imul r8, rax, TOK_SIZE
    lea r9, [toks]
    add r8, r9
    mov [r8+TK_KIND], rdi
    mov [r8+TK_VAL], rsi
    mov [r8+TK_PTR], rdx
    mov [r8+TK_LEN], rcx
    mov [r8+TK_LINE], r14
    inc rax
    mov [ntok], rax
    ret
.full:
    lea rdi, [msg_full]
    jmp lex_fatal

; dil = символ → eax = 1, если [A-Za-z0-9_]
is_ident_char:
    movzx ecx, dil
    mov eax, 1
    cmp cl, '_'
    je .yes
    lea edx, [rcx-'0']
    cmp edx, 10
    jb .yes
    or ecx, 0x20
    sub ecx, 'a'
    cmp ecx, 26
    jb .yes
    xor eax, eax
.yes:
    ret

; rdi = указатель, rsi = длина, rdx = таблица (длина, байты, значение), rcx = значение по умолчанию
table_lookup:
    mov r8, rdx
.loop:
    movzx r9d, byte [r8]
    test r9d, r9d
    jz .miss
    cmp r9, rsi
    jne .next
    xor r10d, r10d
.cmp:
    cmp r10, r9
    jae .hit
    mov al, [r8+1+r10]
    cmp al, [rdi+r10]
    jne .next
    inc r10
    jmp .cmp
.hit:
    movzx eax, byte [r8+1+r9]
    ret
.next:
    lea r8, [r8+r9+2]
    jmp .loop
.miss:
    mov rax, rcx
    ret

; Читает один символ литерала (с экранированием) по r12 → eax, сдвигает r12
lex_char:
    cmp r12, r13
    jae .bad
    movzx eax, byte [r12]
    inc r12
    cmp al, 92
    jne .done
    cmp r12, r13
    jae .bad
    movzx eax, byte [r12]
    inc r12
    cmp al, 'n'
    je .n
    cmp al, 't'
    je .t
    cmp al, 'r'
    je .r
    cmp al, '0'
    je .z
    cmp al, 92
    je .done
    cmp al, 39
    je .done
    cmp al, '"'
    je .done
.bad:
    lea rdi, [msg_bad_escape]
    jmp lex_fatal
.n: mov eax, 10
    ret
.t: mov eax, 9
    ret
.r: mov eax, 13
    ret
.z: xor eax, eax
.done:
    ret

lex:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea r12, [src]
    mov r13, r12
    add r13, [src_len]
    mov r14, 1
.next:
    cmp r12, r13
    jae .eof
    movzx eax, byte [r12]
    cmp al, 10
    je .newline
    cmp al, ' '
    je .skip
    cmp al, 9
    je .skip
    cmp al, 13
    je .skip
    cmp al, '/'
    jne .token
    lea rcx, [r12+1]
    cmp rcx, r13
    jae .token
    cmp byte [r12+1], '/'
    jne .token
.comment:
    inc r12
    cmp r12, r13
    jae .eof
    cmp byte [r12], 10
    jne .comment
    jmp .next
.newline:
    inc r14
.skip:
    inc r12
    jmp .next

.token:
    mov rbx, r12
    mov ecx, eax
    or ecx, 0x20
    sub ecx, 'a'
    cmp ecx, 26
    jb .ident
    cmp al, '_'
    je .ident
    lea ecx, [rax-'0']
    cmp ecx, 10
    jb .number
    cmp al, 39
    je .char
    cmp al, '"'
    je .string
    jmp .punct

.emit:
    mov rdx, rbx
    mov rcx, r12
    sub rcx, rbx
    call add_tok
    jmp .next

.ident:
    inc r12
.ident_loop:
    cmp r12, r13
    jae .ident_end
    movzx edi, byte [r12]
    call is_ident_char
    test eax, eax
    jz .ident_end
    inc r12
    jmp .ident_loop
.ident_end:
    mov rdi, rbx
    mov rsi, r12
    sub rsi, rbx
    lea rdx, [kw_table]
    mov ecx, T_IDENT
    call table_lookup
    mov rdi, rax
    xor esi, esi
    jmp .emit

.number:
    xor r15d, r15d
    cmp al, '0'
    jne .dec
    lea rcx, [r12+1]
    cmp rcx, r13
    jae .dec
    movzx ecx, byte [r12+1]
    or ecx, 0x20
    cmp ecx, 'x'
    jne .dec
    add r12, 2
.hex:
    cmp r12, r13
    jae .num_end
    movzx eax, byte [r12]
    lea ecx, [rax-'0']
    cmp ecx, 10
    jb .hex_digit
    mov ecx, eax
    or ecx, 0x20
    sub ecx, 'a'
    cmp ecx, 6
    jae .num_end
    add ecx, 10
.hex_digit:
    shl r15, 4
    add r15, rcx
    inc r12
    jmp .hex
.dec:
    cmp r12, r13
    jae .num_end
    movzx eax, byte [r12]
    sub eax, '0'
    cmp eax, 10
    jae .num_end
    imul r15, r15, 10
    add r15, rax
    inc r12
    jmp .dec
.num_end:
    mov edi, T_INT
    mov rsi, r15
    jmp .emit

.char:
    inc r12
    call lex_char
    cmp r12, r13
    jae .bad_charlit
    cmp byte [r12], 39
    jne .bad_charlit
    inc r12
    mov edi, T_INT
    mov esi, eax
    jmp .emit
.bad_charlit:
    lea rdi, [msg_bad_charlit]
    jmp lex_fatal

.string:
    inc r12
    mov r15, [data_len]
.str_loop:
    cmp r12, r13
    jae .bad_str
    movzx eax, byte [r12]
    cmp al, '"'
    je .str_end
    cmp al, 10
    je .bad_str
    call lex_char
    mov rcx, [data_len]
    cmp rcx, DATA_MAX - 16
    jae .data_full
    lea rdx, [data]
    mov [rdx+rcx], al
    inc qword [data_len]
    jmp .str_loop
.str_end:
    inc r12
    mov rcx, [data_len]
    lea rdx, [data]
    mov byte [rdx+rcx], 0
    inc qword [data_len]
    mov edi, T_STR
    lea rsi, [r15 + DATA_BASE]
    jmp .emit
.bad_str:
    lea rdi, [msg_bad_str]
    jmp lex_fatal
.data_full:
    lea rdi, [msg_full]
    jmp lex_fatal

.punct:
    lea rcx, [r12+1]
    cmp rcx, r13
    jae .single
    movzx ecx, byte [r12+1]
    lea rsi, [two_table]
.two_loop:
    movzx edx, byte [rsi]
    test edx, edx
    jz .single
    cmp dl, al
    jne .two_next
    cmp cl, [rsi+1]
    jne .two_next
    movzx edi, word [rsi+2]
    add r12, 2
    xor esi, esi
    jmp .emit
.two_next:
    add rsi, 4
    jmp .two_loop
.single:
    lea rsi, [single_chars]
.single_loop:
    movzx edx, byte [rsi]
    test edx, edx
    jz .bad
    cmp dl, al
    je .single_ok
    inc rsi
    jmp .single_loop
.single_ok:
    inc r12
    mov edi, eax
    xor esi, esi
    jmp .emit
.bad:
    lea rdi, [msg_bad_char]
    jmp lex_fatal

.eof:
    mov edi, T_EOF
    xor esi, esi
    mov rdx, r12
    xor ecx, ecx
    call add_tok
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; Токены для разбора
; ----------------------------------------------------------------------------

; rax = адрес текущего токена
tk_addr:
    mov rax, [pos]
    imul rax, rax, TOK_SIZE
    lea rcx, [toks]
    add rax, rcx
    ret

; rax = вид текущего токена
tk_kind:
    call tk_addr
    mov rax, [rax+TK_KIND]
    ret

; rax = вид следующего токена
tk_kind_next:
    mov rax, [pos]
    inc rax
    imul rax, rax, TOK_SIZE
    lea rcx, [toks]
    mov rax, [rcx+rax+TK_KIND]
    ret

advance:
    inc qword [pos]
    ret

; rdi = ожидаемый вид (ASCII-знак)
expect:
    push rdi
    call tk_kind
    pop rdi
    cmp rax, rdi
    jne .err
    inc qword [pos]
    ret
.err:
    mov [msg_expected+10], dil
    lea rdi, [msg_expected]
    jmp fatal

; → rax = адрес токена-идентификатора, позиция сдвигается
expect_ident:
    call tk_addr
    cmp qword [rax+TK_KIND], T_IDENT
    jne .err
    inc qword [pos]
    ret
.err:
    lea rdi, [msg_exp_ident]
    jmp fatal

; ----------------------------------------------------------------------------
; Генерация кода
; ----------------------------------------------------------------------------

; dil → code
emit_byte:
    mov rax, [code_len]
    cmp rax, CODE_MAX - 16
    jae limit_exceeded
    lea rcx, [code]
    mov [rcx+rax], dil
    inc rax
    mov [code_len], rax
    ret

; edi → code
emit_u32:
    mov rax, [code_len]
    cmp rax, CODE_MAX - 16
    jae limit_exceeded
    lea rcx, [code]
    mov [rcx+rax], edi
    add rax, 4
    mov [code_len], rax
    ret

; rdi → code
emit_u64:
    mov rax, [code_len]
    cmp rax, CODE_MAX - 16
    jae limit_exceeded
    lea rcx, [code]
    mov [rcx+rax], rdi
    add rax, 8
    mov [code_len], rax
    ret

; rsi = последовательность (байт длины + байты)
emit_seq:
    movzx ecx, byte [rsi]
    inc rsi
    mov rax, [code_len]
    cmp rax, CODE_MAX - 300
    jae limit_exceeded
    lea rdi, [code]
    add rdi, rax
    add rax, rcx
    mov [code_len], rax
    rep movsb
    ret

; rsi = опкод перехода → rax = позиция поля rel32 (заполняется позже)
emit_jump_fwd:
    call emit_seq
    mov rax, [code_len]
    push rax
    xor edi, edi
    call emit_u32
    pop rax
    ret

; rdi = позиция поля rel32, rsi = цель перехода
patch_rel:
    mov rax, rsi
    sub rax, rdi
    sub rax, 4
    lea rcx, [code]
    mov [rcx+rdi], eax
    ret

; ----------------------------------------------------------------------------
; Таблицы имён
; ----------------------------------------------------------------------------

; rdi, rsi = первая строка; rdx, rcx = вторая → eax = 1, если равны
memeq:
    cmp rsi, rcx
    jne .no
    xor r8d, r8d
.l: cmp r8, rsi
    jae .yes
    mov al, [rdi+r8]
    cmp al, [rdx+r8]
    jne .no
    inc r8
    jmp .l
.yes:
    mov eax, 1
    ret
.no:
    xor eax, eax
    ret

; rdi = индекс → rax = адрес записи символа
sym_addr:
    imul rax, rdi, SYM_SIZE
    lea rcx, [syms]
    add rax, rcx
    ret

; rdi = имя, rsi = длина → rax = индекс или -1
sym_find:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
.l: cmp rbx, [nsyms]
    jae .nf
    mov rdi, rbx
    call sym_addr
    mov r14, rax
    mov rdi, r12
    mov rsi, r13
    mov rdx, [r14+SY_PTR]
    mov rcx, [r14+SY_LEN]
    call memeq
    test eax, eax
    jnz .found
    inc rbx
    jmp .l
.found:
    mov rax, rbx
    jmp .ret
.nf:
    mov rax, -1
.ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rdi = имя, rsi = длина, rdx = вид, rcx = значение, r8 = доп. поле → rax = индекс
sym_add:
    mov rax, [nsyms]
    cmp rax, SYM_MAX
    jae limit_exceeded
    imul r9, rax, SYM_SIZE
    lea r10, [syms]
    add r9, r10
    mov [r9+SY_PTR], rdi
    mov [r9+SY_LEN], rsi
    mov [r9+SY_KIND], rdx
    mov [r9+SY_VAL], rcx
    mov [r9+SY_EXTRA], r8
    inc qword [nsyms]
    ret

; rdi = имя, rsi = длина → ошибка, если имя уже занято
check_dup:
    call sym_find
    cmp rax, -1
    jne .dup
    ret
.dup:
    lea rdi, [msg_dup]
    jmp fatal

; rdi = имя, rsi = длина → rax = индекс функции (создаётся, если ещё не встречалась)
fn_sym:
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    call sym_find
    cmp rax, -1
    je .add
    push rax
    mov rdi, rax
    call sym_addr
    cmp qword [rax+SY_KIND], S_FN
    pop rax
    jne .err
    jmp .ret
.add:
    mov rdi, r12
    mov rsi, r13
    mov edx, S_FN
    mov rcx, -1
    mov r8, -1
    call sym_add
.ret:
    pop r13
    pop r12
    ret
.err:
    lea rdi, [msg_not_fn]
    jmp fatal

; rdi = имя, rsi = длина → rax = смещение, edx = 1, если найдено
loc_find:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    mov rbx, [nlocs]
.l: test rbx, rbx
    jz .nf
    dec rbx
    imul r14, rbx, LOC_SIZE
    lea rax, [locs]
    add r14, rax
    mov rdi, r12
    mov rsi, r13
    mov rdx, [r14+LO_PTR]
    mov rcx, [r14+LO_LEN]
    call memeq
    test eax, eax
    jz .l
    mov rax, [r14+LO_OFF]
    mov edx, 1
    jmp .ret
.nf:
    xor eax, eax
    xor edx, edx
.ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rdi = имя, rsi = длина, rdx = смещение
loc_add:
    mov rax, [nlocs]
    cmp rax, LOC_MAX
    jae limit_exceeded
    imul r9, rax, LOC_SIZE
    lea r10, [locs]
    add r9, r10
    mov [r9+LO_PTR], rdi
    mov [r9+LO_LEN], rsi
    mov [r9+LO_OFF], rdx
    inc qword [nlocs]
    ret

; rdi = позиция rel32, rsi = символ, rdx = число аргументов (-1 — не проверять), rcx = строка
fix_add:
    mov rax, [nfix]
    cmp rax, FIX_MAX
    jae limit_exceeded
    imul r9, rax, FIX_SIZE
    lea r10, [fixes]
    add r9, r10
    mov [r9+FX_POS], rdi
    mov [r9+FX_SYM], rsi
    mov [r9+FX_ARGC], rdx
    mov [r9+FX_LINE], rcx
    inc qword [nfix]
    ret

; ----------------------------------------------------------------------------
; Программа верхнего уровня
; ----------------------------------------------------------------------------

compile:
    EMIT s_start
    EMIT s_call
    lea rdi, [str_main]
    mov esi, 4
    call fn_sym
    mov rsi, rax
    mov rdi, [code_len]
    mov rdx, -1
    mov ecx, 1
    call fix_add
    xor edi, edi
    call emit_u32
    EMIT s_exit
.top:
    call tk_kind
    cmp rax, T_EOF
    je .done
    cmp rax, T_FN
    je .fn
    cmp rax, T_VAR
    je .var
    cmp rax, T_CONST
    je .const
    lea rdi, [msg_top]
    jmp fatal
.fn:
    call parse_fn
    jmp .top
.var:
    call parse_global
    jmp .top
.const:
    call parse_const
    jmp .top
.done:
    jmp resolve_fixups

; [-] целое → rax
parse_const_value:
    call tk_kind
    cmp rax, '-'
    jne .pos
    call advance
    call tk_addr
    cmp qword [rax+TK_KIND], T_INT
    jne .err
    mov rax, [rax+TK_VAL]
    neg rax
    jmp .adv
.pos:
    call tk_addr
    cmp qword [rax+TK_KIND], T_INT
    jne .err
    mov rax, [rax+TK_VAL]
.adv:
    push rax
    call advance
    pop rax
    ret
.err:
    lea rdi, [msg_exp_int]
    jmp fatal

; const ИМЯ = [-]целое
parse_const:
    push rbx
    call advance
    call expect_ident
    mov rbx, rax
    mov rdi, [rbx+TK_PTR]
    mov rsi, [rbx+TK_LEN]
    call check_dup
    mov edi, '='
    call expect
    call parse_const_value
    mov rcx, rax
    mov rdi, [rbx+TK_PTR]
    mov rsi, [rbx+TK_LEN]
    mov edx, S_CONST
    xor r8d, r8d
    call sym_add
    pop rbx
    ret

; var ИМЯ: тип [= [-]целое]
parse_global:
    push rbx
    call advance
    call expect_ident
    mov rbx, rax
    mov rdi, [rbx+TK_PTR]
    mov rsi, [rbx+TK_LEN]
    call check_dup
    mov edi, ':'
    call expect
    call expect_ident
    call tk_kind
    cmp rax, '='
    jne .zero
    call advance
    call parse_const_value
    jmp .place
.zero:
    xor eax, eax
.place:
    mov rcx, [data_len]
    add rcx, 7
    and rcx, -8
    cmp rcx, DATA_MAX - 16
    jae limit_exceeded
    lea rdx, [data]
    mov [rdx+rcx], rax
    lea r8, [rcx+8]
    mov [data_len], r8
    add rcx, DATA_BASE
    mov rdi, [rbx+TK_PTR]
    mov rsi, [rbx+TK_LEN]
    mov edx, S_VAR
    xor r8d, r8d
    call sym_add
    pop rbx
    ret

; fn ИМЯ(параметры) [-> тип] { ... }
parse_fn:
    push rbx
    push r12
    push r13
    call advance
    call expect_ident
    mov rbx, rax
    mov rdi, [rbx+TK_PTR]
    mov rsi, [rbx+TK_LEN]
    call sym_find
    cmp rax, -1
    je .new
    mov r12, rax
    mov rdi, rax
    call sym_addr
    cmp qword [rax+SY_KIND], S_FN
    jne .dup
    cmp qword [rax+SY_VAL], -1
    jne .dup
    jmp .have
.new:
    mov rdi, [rbx+TK_PTR]
    mov rsi, [rbx+TK_LEN]
    mov edx, S_FN
    mov rcx, -1
    mov r8, -1
    call sym_add
    mov r12, rax
.have:
    mov rdi, r12
    call sym_addr
    mov rcx, [code_len]
    mov [rax+SY_VAL], rcx
    mov qword [nlocs], 0
    mov qword [frame], 0
    mov edi, '('
    call expect
    xor r13d, r13d
    call tk_kind
    cmp rax, ')'
    je .params_done
.param:
    call expect_ident
    mov rdi, [rax+TK_PTR]
    mov rsi, [rax+TK_LEN]
    xor edx, edx
    call loc_add
    inc r13
    mov edi, ':'
    call expect
    call expect_ident
    call tk_kind
    cmp rax, ','
    jne .params_done
    call advance
    jmp .param
.params_done:
    mov edi, ')'
    call expect
    ; параметр i лежит по адресу rbp + 16 + 8*(n-1-i)
    xor ecx, ecx
.offsets:
    cmp rcx, r13
    jae .offsets_done
    mov rax, r13
    sub rax, rcx
    dec rax
    shl rax, 3
    add rax, 16
    imul rdx, rcx, LOC_SIZE
    lea r8, [locs]
    mov [r8+rdx+LO_OFF], rax
    inc rcx
    jmp .offsets
.offsets_done:
    mov rdi, r12
    call sym_addr
    mov [rax+SY_EXTRA], r13
    call tk_kind
    cmp rax, T_ARROW
    jne .body
    call advance
    call expect_ident
.body:
    EMIT s_prologue
    mov rbx, [code_len]
    xor edi, edi
    call emit_u32
    mov qword [cont_target], -1
    call parse_block
    EMIT s_ret0
    EMIT s_epilogue
    mov rax, [frame]
    lea rcx, [code]
    mov [rcx+rbx], eax
    pop r13
    pop r12
    pop rbx
    ret
.dup:
    lea rdi, [msg_dup]
    mov rsi, rbx
    jmp fatal_at

resolve_fixups:
    push rbx
    push r12
    xor ebx, ebx
.l: cmp rbx, [nfix]
    jae .done
    imul r12, rbx, FIX_SIZE
    lea rax, [fixes]
    add r12, rax
    mov rdi, [r12+FX_SYM]
    call sym_addr
    mov rcx, [rax+SY_VAL]
    cmp rcx, -1
    je .undef
    mov rdx, [r12+FX_ARGC]
    cmp rdx, -1
    je .ok
    cmp rdx, [rax+SY_EXTRA]
    jne .argc
.ok:
    mov rdi, [r12+FX_POS]
    mov rsi, rcx
    call patch_rel
    inc rbx
    jmp .l
.done:
    pop r12
    pop rbx
    ret
.undef:
    lea rdi, [msg_undef]
    jmp .err
.argc:
    lea rdi, [msg_argc]
.err:
    mov rsi, rax
    mov rdx, [r12+FX_LINE]
    jmp fatal_sym

; ----------------------------------------------------------------------------
; Операторы
; ----------------------------------------------------------------------------

parse_block:
    push rbx
    mov edi, '{'
    call expect
    mov rbx, [nlocs]
.l: call tk_kind
    cmp rax, '}'
    je .end
    cmp rax, T_EOF
    je .eof
    call parse_stmt
    jmp .l
.end:
    call advance
    mov [nlocs], rbx
    pop rbx
    ret
.eof:
    lea rdi, [msg_eof_block]
    jmp fatal

parse_stmt:
    push rbx
    call tk_kind
    cmp rax, T_LET
    je .let
    cmp rax, T_VAR
    je .let
    cmp rax, T_IF
    je .if
    cmp rax, T_WHILE
    je .while
    cmp rax, T_RETURN
    je .return
    cmp rax, T_BREAK
    je .break
    cmp rax, T_CONTINUE
    je .continue
    cmp rax, T_IDENT
    je .maybe_assign
.expr:
    call parse_expr
    jmp .done

.maybe_assign:
    call tk_kind_next
    cmp rax, '='
    jne .expr
    call tk_addr
    mov rbx, rax
    call advance
    call advance
    call parse_expr
    mov rdi, [rbx+TK_PTR]
    mov rsi, [rbx+TK_LEN]
    call loc_find
    test edx, edx
    jz .assign_global
    push rax
    EMIT s_store_local
    pop rdi
    call emit_u32
    jmp .done
.assign_global:
    mov rdi, [rbx+TK_PTR]
    mov rsi, [rbx+TK_LEN]
    call sym_find
    cmp rax, -1
    je .not_var
    mov rdi, rax
    call sym_addr
    cmp qword [rax+SY_KIND], S_VAR
    jne .not_var
    push qword [rax+SY_VAL]
    EMIT s_mov_rcx_imm
    pop rdi
    call emit_u64
    EMIT s_store_rcx
    jmp .done
.not_var:
    lea rdi, [msg_not_var]
    mov rsi, rbx
    jmp fatal_at

.let:
    call advance
    call expect_ident
    mov rbx, rax
    call tk_kind
    cmp rax, ':'
    jne .let_value
    call advance
    call expect_ident
.let_value:
    mov edi, '='
    call expect
    call parse_expr
    mov rax, [frame]
    add rax, 8
    mov [frame], rax
    neg rax
    push rax
    EMIT s_store_local
    mov rdi, [rsp]
    call emit_u32
    pop rdx
    mov rdi, [rbx+TK_PTR]
    mov rsi, [rbx+TK_LEN]
    call loc_add
    jmp .done

.if:
    call parse_if
    jmp .done

.while:
    call parse_while
    jmp .done

.return:
    call tk_addr
    mov rbx, [rax+TK_LINE]
    call advance
    call tk_addr
    cmp qword [rax+TK_KIND], '}'
    je .return_void
    cmp [rax+TK_LINE], rbx
    jne .return_void
    call parse_expr
    jmp .return_emit
.return_void:
    EMIT s_ret0
.return_emit:
    EMIT s_epilogue
    jmp .done

.break:
    cmp qword [cont_target], -1
    je .no_loop
    call advance
    lea rsi, [s_jmp]
    call emit_jump_fwd
    mov rcx, [nbrk]
    cmp rcx, BRK_MAX
    jae limit_exceeded
    lea rdx, [brks]
    mov [rdx+rcx*8], rax
    inc qword [nbrk]
    jmp .done

.continue:
    cmp qword [cont_target], -1
    je .no_loop
    call advance
    EMIT s_jmp
    mov rbx, [code_len]
    xor edi, edi
    call emit_u32
    mov rdi, rbx
    mov rsi, [cont_target]
    call patch_rel
    jmp .done

.no_loop:
    lea rdi, [msg_no_loop]
    jmp fatal

.done:
    pop rbx
    ret

; if условие { ... } [else if ... | else { ... }]
parse_if:
    push rbx
    push r12
    call advance
    call parse_expr
    EMIT s_test
    lea rsi, [s_jz]
    call emit_jump_fwd
    mov rbx, rax
    call parse_block
    call tk_kind
    cmp rax, T_ELSE
    jne .no_else
    call advance
    lea rsi, [s_jmp]
    call emit_jump_fwd
    mov r12, rax
    mov rdi, rbx
    mov rsi, [code_len]
    call patch_rel
    call tk_kind
    cmp rax, T_IF
    jne .else_block
    call parse_if
    jmp .else_done
.else_block:
    call parse_block
.else_done:
    mov rdi, r12
    mov rsi, [code_len]
    call patch_rel
    jmp .ret
.no_else:
    mov rdi, rbx
    mov rsi, [code_len]
    call patch_rel
.ret:
    pop r12
    pop rbx
    ret

; while условие { ... }
parse_while:
    push rbx
    push r12
    push r13
    push r14
    call advance
    mov r13, [cont_target]
    mov r14, [nbrk]
    mov rbx, [code_len]
    mov [cont_target], rbx
    call parse_expr
    EMIT s_test
    lea rsi, [s_jz]
    call emit_jump_fwd
    mov r12, rax
    call parse_block
    EMIT s_jmp
    mov rdi, [code_len]
    push rdi
    xor edi, edi
    call emit_u32
    pop rdi
    mov rsi, rbx
    call patch_rel
    mov rdi, r12
    mov rsi, [code_len]
    call patch_rel
.breaks:
    cmp [nbrk], r14
    jbe .breaks_done
    dec qword [nbrk]
    mov rcx, [nbrk]
    lea rdx, [brks]
    mov rdi, [rdx+rcx*8]
    mov rsi, [code_len]
    call patch_rel
    jmp .breaks
.breaks_done:
    mov [cont_target], r13
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ----------------------------------------------------------------------------
; Выражения. Каждая функция генерирует код, оставляющий значение в rax.
; Приоритеты как в Go: || < && < сравнения < + - | ^ < * / % << >> &
; ----------------------------------------------------------------------------

parse_expr:
    jmp parse_or

parse_or:
    push rbx
    call parse_and
    call tk_kind
    cmp rax, T_OROR
    jne .ret
    EMIT s_bool
    xor ebx, ebx
.loop:
    call tk_kind
    cmp rax, T_OROR
    jne .patch
    call advance
    EMIT s_test
    lea rsi, [s_jnz]
    call emit_jump_fwd
    push rax
    inc rbx
    call parse_and
    EMIT s_bool
    jmp .loop
.patch:
    test rbx, rbx
    jz .ret
    pop rdi
    mov rsi, [code_len]
    call patch_rel
    dec rbx
    jmp .patch
.ret:
    pop rbx
    ret

parse_and:
    push rbx
    call parse_cmp
    call tk_kind
    cmp rax, T_ANDAND
    jne .ret
    EMIT s_bool
    xor ebx, ebx
.loop:
    call tk_kind
    cmp rax, T_ANDAND
    jne .patch
    call advance
    EMIT s_test
    lea rsi, [s_jz]
    call emit_jump_fwd
    push rax
    inc rbx
    call parse_cmp
    EMIT s_bool
    jmp .loop
.patch:
    test rbx, rbx
    jz .ret
    pop rdi
    mov rsi, [code_len]
    call patch_rel
    dec rbx
    jmp .patch
.ret:
    pop rbx
    ret

parse_cmp:
    call parse_add
    call tk_kind
    mov ecx, 0x94
    cmp rax, T_EQ
    je .op
    mov ecx, 0x95
    cmp rax, T_NE
    je .op
    mov ecx, 0x9C
    cmp rax, '<'
    je .op
    mov ecx, 0x9E
    cmp rax, T_LE
    je .op
    mov ecx, 0x9F
    cmp rax, '>'
    je .op
    mov ecx, 0x9D
    cmp rax, T_GE
    je .op
    ret
.op:
    push rcx
    call advance
    EMIT s_push_rax
    call parse_add
    EMIT s_pop_swap
    EMIT s_cmp
    pop rdi
    call emit_byte
    EMIT s_setcc_tail
    ret

parse_add:
    call parse_mul
.loop:
    call tk_kind
    lea rsi, [s_add]
    cmp rax, '+'
    je .op
    lea rsi, [s_sub]
    cmp rax, '-'
    je .op
    lea rsi, [s_or]
    cmp rax, '|'
    je .op
    lea rsi, [s_xor]
    cmp rax, '^'
    je .op
    ret
.op:
    push rsi
    call advance
    EMIT s_push_rax
    call parse_mul
    EMIT s_pop_swap
    pop rsi
    call emit_seq
    jmp .loop

parse_mul:
    call parse_unary
.loop:
    call tk_kind
    lea rsi, [s_mul]
    cmp rax, '*'
    je .op
    lea rsi, [s_div]
    cmp rax, '/'
    je .op
    lea rsi, [s_mod]
    cmp rax, '%'
    je .op
    lea rsi, [s_shl]
    cmp rax, T_SHL
    je .op
    lea rsi, [s_shr]
    cmp rax, T_SHR
    je .op
    lea rsi, [s_and]
    cmp rax, '&'
    je .op
    ret
.op:
    push rsi
    call advance
    EMIT s_push_rax
    call parse_unary
    EMIT s_pop_swap
    pop rsi
    call emit_seq
    jmp .loop

parse_unary:
    call tk_kind
    lea rsi, [s_neg]
    cmp rax, '-'
    je .op
    lea rsi, [s_lnot]
    cmp rax, '!'
    je .op
    lea rsi, [s_bnot]
    cmp rax, '~'
    je .op
    jmp parse_primary
.op:
    push rsi
    call advance
    call parse_unary
    pop rsi
    jmp emit_seq

parse_primary:
    push rbx
    call tk_addr
    mov rbx, rax
    mov rax, [rbx+TK_KIND]
    cmp rax, T_INT
    je .imm
    cmp rax, T_STR
    je .imm
    cmp rax, '('
    je .paren
    cmp rax, T_IDENT
    je .ident
    lea rdi, [msg_exp_expr]
    jmp fatal
.imm:
    call advance
    EMIT s_mov_rax_imm
    mov rdi, [rbx+TK_VAL]
    call emit_u64
    jmp .ret
.paren:
    call advance
    call parse_expr
    mov edi, ')'
    call expect
    jmp .ret
.ident:
    call advance
    call tk_kind
    cmp rax, '('
    jne .var
    mov rdi, rbx
    call parse_call
    jmp .ret
.var:
    mov rdi, [rbx+TK_PTR]
    mov rsi, [rbx+TK_LEN]
    call loc_find
    test edx, edx
    jz .global
    push rax
    EMIT s_load_local
    pop rdi
    call emit_u32
    jmp .ret
.global:
    mov rdi, [rbx+TK_PTR]
    mov rsi, [rbx+TK_LEN]
    call sym_find
    cmp rax, -1
    je .unknown
    mov rdi, rax
    call sym_addr
    mov rcx, [rax+SY_KIND]
    push qword [rax+SY_VAL]
    cmp rcx, S_CONST
    je .const
    cmp rcx, S_VAR
    je .gvar
    lea rdi, [msg_fn_value]
    mov rsi, rbx
    jmp fatal_at
.const:
    EMIT s_mov_rax_imm
    pop rdi
    call emit_u64
    jmp .ret
.gvar:
    EMIT s_mov_rax_imm
    pop rdi
    call emit_u64
    EMIT s_deref
    jmp .ret
.unknown:
    lea rdi, [msg_unknown]
    mov rsi, rbx
    jmp fatal_at
.ret:
    pop rbx
    ret

; rdi = токен имени; текущий токен — '('
parse_call:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    call advance
    xor r12d, r12d
    call tk_kind
    cmp rax, ')'
    je .args_done
.arg:
    call parse_expr
    EMIT s_push_rax
    inc r12
    call tk_kind
    cmp rax, ','
    jne .args_done
    call advance
    jmp .arg
.args_done:
    mov edi, ')'
    call expect
    mov rdi, [rbx+TK_PTR]
    mov rsi, [rbx+TK_LEN]
    lea rdx, [builtin_table]
    xor ecx, ecx
    call table_lookup
    cmp rax, 1
    je .load8
    cmp rax, 2
    je .load64
    cmp rax, 3
    je .store8
    cmp rax, 4
    je .store64
    cmp rax, 5
    je .syscall
    mov rdi, [rbx+TK_PTR]
    mov rsi, [rbx+TK_LEN]
    call fn_sym
    mov r13, rax
    EMIT s_call
    mov rdi, [code_len]
    mov rsi, r13
    mov rdx, r12
    mov rcx, [rbx+TK_LINE]
    call fix_add
    xor edi, edi
    call emit_u32
    test r12, r12
    jz .ret
    EMIT s_add_rsp
    mov rdi, r12
    shl rdi, 3
    call emit_u32
    jmp .ret
.load8:
    cmp r12, 1
    jne .bad_args
    EMIT s_load8
    jmp .ret
.load64:
    cmp r12, 1
    jne .bad_args
    EMIT s_load64
    jmp .ret
.store8:
    cmp r12, 2
    jne .bad_args
    EMIT s_store8
    jmp .ret
.store64:
    cmp r12, 2
    jne .bad_args
    EMIT s_store64
    jmp .ret
.syscall:
    cmp r12, 1
    jb .bad_args
    cmp r12, 7
    ja .bad_args
.sys_pop:
    test r12, r12
    jz .sys_emit
    dec r12
    lea rax, [pop_table]
    mov rsi, [rax+r12*8]
    call emit_seq
    jmp .sys_pop
.sys_emit:
    EMIT s_syscall
.ret:
    pop r13
    pop r12
    pop rbx
    ret
.bad_args:
    lea rdi, [msg_builtin]
    mov rsi, rbx
    jmp fatal_at

; ----------------------------------------------------------------------------
; Запись ELF
; ----------------------------------------------------------------------------

; rdi = fd, rsi = буфер, rdx = длина
write_all:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
.l: test r13, r13
    jz .d
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov eax, SYS_WRITE
    syscall
    test rax, rax
    jle .err
    add r12, rax
    sub r13, rax
    jmp .l
.d: pop r13
    pop r12
    pop rbx
    ret
.err:
    lea rdi, [msg_out]
    call print_err
    EXIT 1

write_elf:
    push rbx
    push r12
    lea rdi, [hdr]
    mov dword [rdi], 0x464C457F             ; \x7FELF
    mov byte [rdi+4], 2                     ; 64 бита
    mov byte [rdi+5], 1                     ; little endian
    mov byte [rdi+6], 1                     ; версия
    mov word [rdi+16], 2                    ; ET_EXEC
    mov word [rdi+18], 0x3E                 ; x86-64
    mov dword [rdi+20], 1
    mov qword [rdi+24], CODE_BASE + HDR_SIZE
    mov qword [rdi+32], 64                  ; заголовки программы сразу за заголовком ELF
    mov word [rdi+52], 64
    mov word [rdi+54], 56
    mov word [rdi+56], 2
    mov word [rdi+58], 64
    ; сегмент кода: заголовки + код, чтение и исполнение
    mov dword [rdi+64], 1
    mov dword [rdi+68], 5
    mov qword [rdi+72], 0
    mov qword [rdi+80], CODE_BASE
    mov qword [rdi+88], CODE_BASE
    mov rax, [code_len]
    add rax, HDR_SIZE
    mov [rdi+96], rax
    mov [rdi+104], rax
    mov qword [rdi+112], 0x1000
    ; сегмент данных: с границы страницы, чтение и запись
    add rax, 0xFFF
    and rax, -0x1000
    mov r12, rax
    mov dword [rdi+120], 1
    mov dword [rdi+124], 6
    mov [rdi+128], rax
    mov qword [rdi+136], DATA_BASE
    mov qword [rdi+144], DATA_BASE
    mov rax, [data_len]
    mov [rdi+152], rax
    mov [rdi+160], rax
    mov qword [rdi+168], 0x1000

    mov rdi, [out_path]
    mov esi, 0x241                          ; O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 493                            ; 0755
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js write_all.err
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [hdr]
    mov edx, HDR_SIZE
    call write_all
    mov rdi, rbx
    lea rsi, [code]
    mov rdx, [code_len]
    call write_all
    mov rdx, r12
    sub rdx, HDR_SIZE
    sub rdx, [code_len]
    mov rdi, rbx
    lea rsi, [zeros]
    call write_all
    mov rdi, rbx
    lea rsi, [data]
    mov rdx, [data_len]
    call write_all
    mov rdi, rbx
    mov eax, SYS_CLOSE
    syscall
    pop r12
    pop rbx
    ret
