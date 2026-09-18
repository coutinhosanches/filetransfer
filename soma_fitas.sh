#!/bin/bash
#
# soma_fitas.sh
#
# Executa:
#   obtool lsvol --barcode <BARCODES> --contents
#
# Soma a coluna Size dos conteúdos de cada fita, aceitando:
#   B / BYTE / BYTES
#   KB / KBYTE / KBYTES / K / KG / KIB
#   MB / MBYTE / MBYTES / M / MIB
#   GB / GBYTE / GBYTES / G / GIB
#   TB / TBYTE / TBYTES / T / TIB
#
# Uso:
#   ./soma_fitas.sh PS0157,PS0184
#   ./soma_fitas.sh PS0157 PS0184 PS0185
#   ./soma_fitas.sh --help
#

set -u
set -o pipefail

SCRIPT_NAME="$(basename "$0")"

usage() {
    cat <<EOF
Uso:
  $SCRIPT_NAME BARCODE[,BARCODE,...]
  $SCRIPT_NAME BARCODE BARCODE ...

Exemplos:
  $SCRIPT_NAME PS0157,PS0184
  $SCRIPT_NAME PS0157 PS0184 PS0185

Descrição:
  Executa 'obtool lsvol --barcode ... --contents' e soma a coluna Size
  individualmente por fita.

  O resultado apresenta:
    - Barcode
    - quantidade de conteúdos/objetos
    - tamanho em GB
    - tamanho em TB
    - total geral

Unidades suportadas:
  B, BYTE, BYTES
  KB, KBYTE, KBYTES, K, KG, KIB
  MB, MBYTE, MBYTES, M, MIB
  GB, GBYTE, GBYTES, G, GIB
  TB, TBYTE, TBYTES, T, TIB
EOF
}

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
esac

# Permite:
#   PS0157,PS0184
# ou:
#   PS0157 PS0184 PS0185
BARCODES=""
for arg in "$@"; do
    if [[ -n "$BARCODES" ]]; then
        BARCODES="${BARCODES},${arg}"
    else
        BARCODES="${arg}"
    fi
done

# Remove espaços acidentais.
BARCODES="$(printf '%s\n' "$BARCODES" | tr -d '[:space:]')"

if [[ -z "$BARCODES" ]]; then
    echo "ERRO: nenhum barcode informado." >&2
    exit 1
fi

if ! command -v obtool >/dev/null 2>&1; then
    echo "ERRO: comando 'obtool' não encontrado no PATH." >&2
    exit 127
fi

echo "============================================================"
echo " Soma de conteúdos das fitas"
echo "============================================================"
echo "Barcodes : $BARCODES"
echo "Comando  : obtool lsvol --barcode $BARCODES --contents"
echo "------------------------------------------------------------"
echo

# Executa o obtool uma única vez para todos os barcodes.
#
# A identificação das linhas é baseada no formato mostrado pelo obtool:
#
# Linha do volume:
#   3573 3573 1 MENSALX8_JUN26_5A-000001 PS0157 MENSALX8_JUN26_5A ...
#
# Linha de conteúdo:
#   1198591 1 1 0 gt-rax8aingest02 97.5 GB ...
#
# Na linha do volume:
#   $1, $2, $3 são numéricos
#   $4 NÃO é numérico
#   $5 é o barcode
#
# Na linha de conteúdo:
#   $1, $2, $3, $4 são numéricos
#   $6 é o valor
#   $7 é a unidade
#
OBTOOL_OUTPUT="$(
    obtool lsvol --barcode "$BARCODES" --contents
)"
OBTOOL_RC=$?

if [[ $OBTOOL_RC -ne 0 ]]; then
    echo "ERRO: o comando obtool terminou com código $OBTOOL_RC." >&2
    exit "$OBTOOL_RC"
fi

if [[ -z "$OBTOOL_OUTPUT" ]]; then
    echo "ERRO: o obtool não retornou dados." >&2
    exit 1
fi

printf '%s\n' "$OBTOOL_OUTPUT" |
awk '
BEGIN {
    current_tape = ""
    current_objects = 0
    current_bytes = 0

    grand_objects = 0
    grand_bytes = 0

    print "BARCODE              OBJETOS          GB            TB"
    print "-------------------- --------------- -------------- -------------"
}

# Linha que identifica o início de uma nova fita.
#
# Exemplo:
# 3573 3573 1 MENSALX8_JUN26_5A-000001 PS0157 MENSALX8_JUN26_5A ...
#
$1 ~ /^[0-9]+$/ &&
$2 ~ /^[0-9]+$/ &&
$3 ~ /^[0-9]+$/ &&
$4 !~ /^[0-9]+$/ &&
$5 !~ /^[0-9]+$/ {

    # Imprime a fita anterior antes de iniciar a próxima.
    if (current_tape != "") {
        printf "%-20s %15d %14.2f %13.2f\n",
               current_tape,
               current_objects,
               current_bytes / 1024^3,
               current_bytes / 1024^4
    }

    current_tape = $5
    current_objects = 0
    current_bytes = 0
    next
}

# Linha de conteúdo.
#
# Exemplo:
# 1198591 1 1 0 gt-rax8aingest02 97.5 GB 06/12.17:43 ...
#
$1 ~ /^[0-9]+$/ &&
$2 ~ /^[0-9]+$/ &&
$3 ~ /^[0-9]+$/ &&
$4 ~ /^[0-9]+$/ &&
$6 ~ /^[0-9]+([.,][0-9]+)?$/ {

    value = $6
    unit = toupper($7)

    gsub(",", ".", value)

    bytes = 0

    if (unit == "B" || unit == "BYTE" || unit == "BYTES") {
        bytes = value
    }
    else if (unit == "K" || unit == "KB" ||
             unit == "KBYTE" || unit == "KBYTES" ||
             unit == "KG" || unit == "KIB") {
        bytes = value * 1024
    }
    else if (unit == "M" || unit == "MB" ||
             unit == "MBYTE" || unit == "MBYTES" ||
             unit == "MIB") {
        bytes = value * 1024^2
    }
    else if (unit == "G" || unit == "GB" ||
             unit == "GBYTE" || unit == "GBYTES" ||
             unit == "GIB") {
        bytes = value * 1024^3
    }
    else if (unit == "T" || unit == "TB" ||
             unit == "TBYTE" || unit == "TBYTES" ||
             unit == "TIB") {
        bytes = value * 1024^4
    }
    else {
        # Unidade desconhecida: ignora a linha.
        next
    }

    current_objects++
    current_bytes += bytes

    grand_objects++
    grand_bytes += bytes
}

END {
    # Imprime a última fita.
    if (current_tape != "") {
        printf "%-20s %15d %14.2f %13.2f\n",
               current_tape,
               current_objects,
               current_bytes / 1024^3,
               current_bytes / 1024^4
    }

    print "-------------------- --------------- -------------- -------------"
    printf "%-20s %15d %14.2f %13.2f\n",
           "TOTAL",
           grand_objects,
           grand_bytes / 1024^3,
           grand_bytes / 1024^4
}
'

AWK_RC=$?

echo
echo "============================================================"
if [[ $AWK_RC -ne 0 ]]; then
    echo "ERRO: falha no processamento do retorno do obtool."
    echo "============================================================"
    exit "$AWK_RC"
fi

echo "Processamento concluído."
echo "============================================================"
