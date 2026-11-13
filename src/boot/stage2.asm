; =============================================================================
; AntLex OS — stage2 (BIOS): cargador de bajo nivel
; -----------------------------------------------------------------------------
; Secuencia:
;   1) lee la cabecera del kernel (valida magia "ALKR")
;   2) carga el kernel por bloques en 0x10000 (límite 512 KiB)
;   3) elige modo VBE lineal 1024x768x32 (o 800x600 / 640x480)
;   4) obtiene el mapa de memoria E820
;   5) activa A20 y entra en modo protegido
;   6) construye tablas de páginas (identidad 4 GiB con páginas de 2 MiB)
;   7) activa modo largo, copia el kernel a 0x100000, borra .bss,
;      rellena boot_info y salta al kernel con RDI = boot_info
;
; Variantes de ensamblado:
;   HDD: nasm -f bin                -o stage2.bin    stage2.asm
;   CD : nasm -f bin -D CD=1        -o stage2_cd.bin stage2.asm
;        (El Torito carga cdboot.img = stage1_cd + stage2 en 0x7C00)
; =============================================================================

%ifndef CD
        %define CD 0
%endif

%if CD
        %define ORG_ADDR   0x7E00          ; contiguo a stage1_cd en 0x7C00
        %define SECT_SIZE  2048
        %define SECT_SHIFT 11
%else
        %define ORG_ADDR   0x8000          ; cargado por stage1 (MBR)
        %define SECT_SIZE  512
        %define SECT_SHIFT 9
%endif

%define KERNEL_OFF_LBA  ((9*1024*1024)/SECT_SIZE)
%define MAX_CHUNK       32                 ; sectores por lectura int 13h
%define HDR_ADDR        0x9000             ; cabecera del kernel (1 sector)
%define KLOAD           0x10000            ; zona de carga temporal (real mode)
%define KBASE           0x100000           ; dirección final del kernel
%define BINFO           0x5000             ; boot_info
%define MM_ADDR         0x6000             ; mapa E820
%define VESA_INFO       0xA000
%define MODE_INFO       0xB000
%define PT_PML4         0x90000
%define PT_PDPT         0x91000

%define SERIAL 0x3F8

%macro TRAZA 1
        mov dx, SERIAL
        mov al, %1
        out dx, al
%endmacro

[BITS 16]
[ORG ORG_ADDR]

stage2:
        cli
        xor ax, ax
        mov ds, ax
        mov es, ax
        mov ss, ax
        mov sp, 0x7C00
        cld
        mov [bi_drive], dl
%if CD
        mov dword [modo_medio], 0x00000002  ; flags: bit1 = medio CD
%else
        mov dword [modo_medio], 0x00000000
%endif

; ------------------------------ 1) cabecera ---------------------------------
        mov word [dap2_cnt], 1
        mov word [dap2_off], HDR_ADDR
        mov word [dap2_seg], 0
        mov dword [dap2_lba], KERNEL_OFF_LBA
        call leer_lba
        TRAZA 'H'
        cmp dword [HDR_ADDR], 0x524B4C41   ; "ALKR"
        jne err_kernel
        ; acotar kernel_size al máximo que puede cargar el cargador (768 KiB):
        ; una cabecera corrupta no debe desbordar la zona de carga
        cmp dword [HDR_ADDR+20], 768*1024
        ja err_kernel
        ; y un tamaño cero también es una cabecera corrupta
        cmp dword [HDR_ADDR+20], 0
        je err_kernel

; ------------------------------ 2) kernel -----------------------------------
        mov eax, [HDR_ADDR+20]             ; kernel_size (bytes)
        mov [k_size], eax
        add eax, SECT_SIZE-1
        shr eax, SECT_SHIFT
        mov [k_sect], eax                  ; sectores restantes
        mov dword [k_lba], KERNEL_OFF_LBA+1
        mov word [k_seg], KLOAD>>4         ; destino: desplazamiento 0 siempre
        mov word [k_off], 0

.bucle_kernel:
        cmp dword [k_sect], 0
        je .kernel_cargado
        ; chunk = min(k_sect, MAX_CHUNK)
        mov ecx, MAX_CHUNK
        cmp ecx, [k_sect]
        jbe .chunk_ok
        mov ecx, [k_sect]
.chunk_ok:
        mov [chunk], cx
        mov [dap2_cnt], cx
        mov ax, [k_seg]
        mov [dap2_seg], ax
        mov ax, [k_off]
        mov [dap2_off], ax
        mov eax, [k_lba]
        mov [dap2_lba], eax
        call leer_lba
        ; avanzar punteros
        movzx eax, word [chunk]
        add [k_lba], eax
        sub [k_sect], eax
        shl eax, SECT_SHIFT-4              ; bytes -> párrafos
        add [k_seg], ax                    ; k_seg es word: add word [k_seg], ax
        jmp .bucle_kernel
.kernel_cargado:
        TRAZA 'K'

; ------------------------------ 3) VBE --------------------------------------
        mov di, VESA_INFO
        mov ax, 0x4F00
        int 0x10
        cmp ax, 0x004F
        jne err_vbe
        cmp dword [VESA_INFO], 0x41534556  ; "VESA"
        jne err_vbe

        ; probar objetivos en orden: 1024x768, 800x600, 640x480
        mov si, objetivos

.objetivo:
        lodsw                              ; ancho objetivo (0 = fin de lista)
        test ax, ax
        jz err_vbe
        mov [obj_x], ax
        lodsw
        mov [obj_y], ax
        mov gs, [VESA_INFO+16]             ; segmento de la lista de modos
        mov si, [VESA_INFO+14]             ; offset de la lista de modos

.modo:
        gs lodsw                           ; número de modo (lista en GS:SI)
        cmp ax, 0xFFFF                     ; fin de la lista
        je .objetivo
        test ax, ax
        jz .modo                           ; 0 = inválido, siguiente
        mov cx, ax
        push si
        push gs
        mov ax, 0x4F01
        mov di, MODE_INFO
        int 0x10
        pop gs
        pop si
        cmp ax, 0x004F
        jne .modo
        ; atributos: se exigen AMBOS bits (0 soportado + 0x80 LFB)
        mov ax, [MODE_INFO]
        and ax, 0x0081
        cmp ax, 0x0081
        jne .modo
        cmp byte [MODE_INFO+25], 32        ; bpp
        jne .modo
        cmp byte [MODE_INFO+27], 6         ; MemoryModel = direct color
        jne .modo
        mov ax, [MODE_INFO+18]             ; X
        cmp ax, [obj_x]
        jne .modo
        mov ax, [MODE_INFO+20]             ; Y
        cmp ax, [obj_y]
        jne .modo
        ; ¡encontrado! activar con LFB (bit 14)
        mov bx, cx
        or bx, 0x4000
        mov ax, 0x4F02
        int 0x10
        cmp ax, 0x004F
        jne err_vbe
        jmp .vbe_ok

.vbe_ok:
        TRAZA 'V'
        ; releer la info del modo activo
        mov cx, bx
        and cx, 0x0FFF
        mov ax, 0x4F01
        mov di, MODE_INFO
        int 0x10
        cmp ax, 0x004F
        jne err_vbe
        mov eax, [MODE_INFO+40]            ; PhysBasePtr
        mov [fb_addr], eax
        mov ax, [MODE_INFO+18]
        mov [fb_w], ax
        mov ax, [MODE_INFO+20]
        mov [fb_h], ax
        mov ax, [MODE_INFO+16]
        mov [fb_pitch], ax

; ------------------------------ 4) E820 -------------------------------------
        xor ebx, ebx
        mov di, MM_ADDR
        xor bp, bp
.e820:
        mov edx, 0x534D4150                 ; "SMAP"
        mov eax, 0xE820
        mov ecx, 24
        int 0x15
        jc .e820_fin
        cmp eax, 0x534D4150
        jne .e820_fin
        add di, 24
        inc bp
        test ebx, ebx
        jz .e820_fin
        cmp bp, 64
        jb .e820
.e820_fin:
        mov [mm_count], bp
        TRAZA 'M'

; ------------------------------ 5) A20 (puerta rápida) ----------------------
        in al, 0x92
        test al, 2
        jnz .a20_ok
        or al, 2
        and al, 0xFE                        ; no tocar bit 0 (reset rápido)
        out 0x92, al
.a20_ok:

; ------------------------------ 6) modo protegido ---------------------------
        TRAZA 'P'
        ; Las rutinas BIOS (int 13h) pueden dejar IF=1: sin IDT válida, un IRQ
        ; del PIC sin remapear (vector 8..15) sería fatal durante la transición.
        cli
        mov al, 0xFF
        out 0xA1, al                       ; enmascarar PIC esclavo
        out 0x21, al                       ; enmascarar PIC maestro
        lgdt [gdtr]
        mov eax, cr0
        or eax, 1                           ; PE
        mov cr0, eax
        jmp 0x08:pm_entry                   ; 0x08 = código 32 bits

; ============================================================================
[BITS 32]
pm_entry:
        TRAZA '3'
        mov ax, 0x10
        mov ds, ax
        mov es, ax
        mov ss, ax
        mov fs, ax
        mov gs, ax

        ; --- tablas de páginas: identidad 4 GiB con páginas de 2 MiB ---
        mov edi, PT_PML4
        xor eax, eax
        mov ecx, 6*1024                     ; 6 páginas (24 KiB)
        rep stosd
        mov eax, PT_PDPT
        or eax, 3                           ; P | RW
        mov [PT_PML4], eax
        ; PDPT[i] = (PT_PDPT+0x1000+i*0x1000) | 3   (i=0..3)
        ; OJO: cada entrada de PDPT ocupa 8 bytes (stride 8, no 4)
        mov eax, PT_PDPT+0x1000
        or eax, 3
        mov [PT_PDPT+0], eax
        mov eax, PT_PDPT+0x2000
        or eax, 3
        mov [PT_PDPT+8], eax
        mov eax, PT_PDPT+0x3000
        or eax, 3
        mov [PT_PDPT+16], eax
        mov eax, PT_PDPT+0x4000
        or eax, 3
        mov [PT_PDPT+24], eax

        ; llenar PD0..PD3: entrada j = (i<<30)+(j<<21) | P|RW|PS
        ; OJO: en modo largo cada entrada ocupa 8 bytes (se escribe la parte
        ; alta a cero explícitamente)
        xor ebx, ebx                        ; índice de directorio
        mov edi, PT_PDPT+0x1000
.llena_pd:
        mov eax, ebx
        shl eax, 30
        or eax, 0x83
        mov edx, 512
.llena_entrada:
        mov [edi], eax                      ; parte baja (dirección+flags)
        mov dword [edi+4], 0                ; parte alta (dirección < 4 GiB)
        add eax, 0x200000
        add edi, 8
        dec edx
        jnz .llena_entrada
        inc ebx
        cmp ebx, 4
        jb .llena_pd
        TRAZA 'T'

        mov eax, PT_PML4
        mov cr3, eax
        TRAZA 'r'

        ; EFER.LME = 1
        mov ecx, 0xC0000080
        rdmsr
        or eax, 0x100
        wrmsr
        TRAZA 'E'

        ; CR4: PAE (obligatorio para modo largo) + SSE (OSFXSR|OSXMMEXCPT)
        mov eax, cr4
        or eax, 0x620
        mov cr4, eax

        ; CR0: PG=1, EM=0
        TRAZA '0'
        mov eax, cr0
        and eax, 0xFFFFFFEF
        or eax, 0x80000000
        mov cr0, eax
        jmp 0x18:lm_entry                   ; 0x18 = código 64 bits (L=1)

; ============================================================================
[BITS 64]
lm_entry:
        mov rsp, 0x7C00
        TRAZA 'L'

        ; copiar kernel 0x10000 -> 0x100000
        mov rsi, KLOAD
        mov rdi, KBASE
        mov ecx, [k_size]
        cld
        rep movsb

        ; borrar .bss
        mov rdi, KBASE
        mov r8d, [HDR_ADDR+12]              ; bss_off
        add rdi, r8
        mov ecx, [HDR_ADDR+16]              ; bss_size
        xor eax, eax
        rep stosb
        TRAZA 'C'

        ; ------------------------------ boot_info ---------------------------
        mov rdi, BINFO
        mov eax, 0x42584C41                 ; "ALXB"
        stosd
        mov eax, 2                          ; versión de boot_info (v2: ALFS)
        stosd
        mov eax, [modo_medio]               ; bit0=UEFI(0), bit1=CD
        stosd
        xor eax, eax
        stosd                               ; reserved
        mov eax, [fb_addr]
        stosq                               ; fb_addr (u64, alto=0)
        movzx eax, word [fb_w]
        stosd
        movzx eax, word [fb_h]
        stosd
        movzx eax, word [fb_pitch]
        stosd
        mov eax, 32
        stosd                               ; bpp
        mov rax, MM_ADDR
        stosq                               ; memmap_ptr
        movzx eax, word [mm_count]
        stosd
        xor eax, eax
        stosd                               ; pad
        mov eax, 13*1024*1024               ; alfs_ptr = offset ALFS en bytes (v2)
        stosq
        mov eax, 16*1024*1024               ; alfs_size en bytes
        stosd
        mov eax, SECT_SIZE
        stosd                               ; sector_size del medio
        movzx eax, byte [bi_drive]
        stosd                               ; boot_drive

        ; ------------------------------ al kernel ---------------------------
        TRAZA 'J'
        mov rdi, BINFO
        mov rax, KBASE
        mov r8d, [HDR_ADDR+8]              ; entry_off (32 bits) de la cabecera
        add rax, r8
        jmp rax

; ============================================================================
;                                  rutinas
; ============================================================================
[BITS 16]
leer_lba:
        mov si, dap2
        mov dl, [bi_drive]
        mov ah, 0x42
        int 0x13
        jnc .ok
        jmp err_disco
.ok:
        ret

; ------------------------------ errores -------------------------------------
err_kernel:
        mov si, m_kernel
        jmp fatal
err_vbe:
        mov si, m_vbe
        jmp fatal
err_disco:
        mov si, m_disco
fatal:
        push si
        mov si, m_fatal
        call teletype
        pop si
        call teletype
        mov si, m_alto
        call teletype
.detente:
        hlt
        jmp .detente

teletype:
        lodsb
        test al, al
        jz .fin
        mov bx, 0x0007
        mov ah, 0x0E
        int 0x10
        jmp teletype
.fin:
        ret

; ============================================================================
;                                  datos
; ============================================================================
align 4
dap2:           db 0x10, 0x00
dap2_cnt:       dw 1
dap2_off:       dw HDR_ADDR
dap2_seg:       dw 0x0000
dap2_lba:       dq KERNEL_OFF_LBA

bi_drive:       db 0
modo_medio:     dd 0

k_size:         dd 0
k_sect:         dd 0
k_lba:          dd 0
k_seg:          dw 0
k_off:          dw 0
chunk:          dw 0

fb_addr:        dd 0
fb_w:           dw 0
fb_h:           dw 0
fb_pitch:       dw 0
mm_count:       dw 0

objetivos:       dw 1024, 768, 800, 600, 640, 480, 0, 0
obj_x:          dw 0
obj_y:          dw 0

m_fatal:        db "ANTLEX stage2: ", 0
m_kernel:       db "cabecera del kernel invalida", 0
m_vbe:          db "sin modo grafico VBE 1024/800/640 x32", 0
m_disco:        db "error de lectura del disco", 0
m_alto:        db " — detenido", 0

; ------------------------------ GDT -----------------------------------------
align 8
gdt:
        dq 0x0000000000000000                 ; nulo
        dq 0x00CF9A000000FFFF                 ; 0x08: código 32 bits (fase PM)
        dq 0x00CF92000000FFFF                 ; 0x10: datos
        dq 0x00AF9A000000FFFF                 ; 0x18: código 64 bits (L=1)
gdtr:
        dw gdtr - gdt - 1
        dd gdt
