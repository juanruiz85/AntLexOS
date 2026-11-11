; =============================================================================
; AntLex OS — stage1 (MBR de 512 bytes, BIOS)
; -----------------------------------------------------------------------------
; Tareas:
;   * comprueba que el BIOS soporta extensiones int 13h (lectura LBA)
;   * carga stage2 desde LBA 1 (32 sectores = 16 KiB) en 0x0000:0x8000
;   * le pasa el control con DL = unidad de arranque
; La tabla de particiones (offset 446) la escribe mkimage; este archivo solo
; deja el hueco. En el offset 3 va la marca "ANTLEX" del medio (la busca el
; bootloader UEFI para identificar discos AntLex).
;
; Ensamblar: nasm -f bin -D STAGE2_SECTORES=32 -o stage1.bin stage1.asm
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
        mov [bi_drive], dl                 ; unidad de arranque (0x80 primer disco)

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

        ; --- cargar stage2: LBA 1 -> 0x0000:0x8000 ---
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
        jmp 0x0000:0x8000                  ; ¡a stage2!

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
                dw STAGE2_SECTORES          ; sectores a leer
                dw 0x8000, 0x0000           ; buffer 0x0000:0x8000
                dq 1                        ; LBA 1 (stage2)
bi_drive:       db 0
msg_noext:      db "ANTLEX: el BIOS no soporta int 13h LBA", 0
msg_err:        db "ANTLEX: error leyendo stage2", 0

; -------- hueco hasta la tabla de particiones (la escribe mkimage) ----------
times 446-($-$$) db 0x00
; 446..509: 4 entradas de particion (16 bytes c/u) — mkimage
times 510-($-$$) db 0x00
dw 0xAA55                                    ; firma de arranque BIOS
