; =============================================================================
; AntLex OS — stage1_cd (imagen de arranque El Torito «sin emulación», 2048 B)
; -----------------------------------------------------------------------------
; La BIOS carga esta imagen en 0x7C00 (catálogo El Torito: entrada por
; defecto, 4 sectores virtuales de 512 B = 2048 B en LBA 20 de la ISO) y
; le pasa DL = unidad de arranque. Con la especificación El Torito sin
; emulación las lecturas int 13h de la unidad usan sectores FÍSICOS de
; 2048 B.
;
; Tareas:
;   * comprueba que el BIOS soporta extensiones int 13h (lectura LBA)
;   * carga stage2_cd desde LBA 1 de la ISO (1 sector de 2048 B) en
;     0x0000:0x7E00 — el código de aquí cabe en los primeros 512 B para
;     no pisarse con lo cargado
;   * le pasa el control con DL = unidad de arranque (stage2_cd pone
;     solo mismo la marca de modo CD en boot_info)
;
; Ensamblar: nasm -f bin -o stage1_cd.bin stage1_cd.asm
; (mkiso lo coloca en LBA 20 y lo referencia desde el catálogo)
; =============================================================================
[BITS 16]
[ORG 0x7C00]

_start:
        jmp short _code
        nop
        db "ANTLEX"                        ; marca del medio (offset 3..8)

_code:
        cli
        xor ax, ax
        mov ds, ax
        mov es, ax
        mov ss, ax
        mov sp, 0x7C00                     ; pila: crece hacia abajo desde 0x7C00
        sti
        cld
        mov [bi_drive], dl                 ; unidad de arranque (CD: suele ser 0xE0+)

        ; --- extensiones int 13h presentes? (AH=41h, BX=55AA -> BX=AA55) ---
        mov ah, 0x41
        mov bx, 0x55AA
        mov dl, [bi_drive]
        int 0x13
        jc .sin_ext
        cmp bx, 0xAA55
        jne .sin_ext
        ; traza serie: 'A' (extensiones int13 OK)
        mov dx, 0x3F8
        mov al, 'A'
        out dx, al

        ; --- cargar stage2_cd: LBA 1 (sector físico de 2048 B) -> 0x7E00 ---
        mov si, dap
        mov ah, 0x42
        mov dl, [bi_drive]
        int 0x13
        jc .error
        ; traza serie: 'B' (stage2 cargado)
        mov dx, 0x3F8
        mov al, 'B'
        out dx, al

        mov dl, [bi_drive]
        jmp 0x0000:0x7E00                  ; ¡a stage2_cd!

.sin_ext:
        mov si, msg_noext
        jmp .imprime
.error:
        mov si, msg_err
.imprime:
        lodsb
        test al, al
        jz .alto
        mov bx, 0x0007
        mov ah, 0x0E                       ; teletype BIOS
        int 0x10
        jmp .imprime
.alto:
        hlt
        jmp .alto

; ------------------------------- datos --------------------------------------
align 4
dap:            db 0x10, 0x00
                dw 1                        ; 1 sector físico (2048 B en CD)
                dw 0x7E00, 0x0000           ; buffer 0x0000:0x7E00
                dq 1                        ; LBA 1 de la ISO (stage2_cd)
bi_drive:       db 0
msg_noext:      db "ANTLEX: el BIOS no soporta int 13h LBA", 0
msg_err:        db "ANTLEX: error leyendo stage2 del CD", 0

; ------------------- relleno hasta exactamente 2048 bytes -------------------
; (la imagen entera es lo que la BIOS copia en 0x7C00; el área 0x7E00 en
; adelante la sobrescribe stage2_cd al cargarse, y este código vive por
; debajo de 0x7DFF)
times 2048-($-$$) db 0x00
