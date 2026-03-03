if status is-interactive
    # Commands to run in interactive sessions can go here
    alias i="sudo pacman -S"
    alias update="sudo pacman -Syu"
    alias bz="bluetuith"
    alias s="pacman -Ssq"
    alias arch="uwufetch"
    alias ghrc ="gh repo create"
    atuin init fish | source
end
function frg
    # The 'fzf' command with 'ripgrep' as the engine
    fzf --ansi --disabled \
        --bind "start:reload:rg --column --line-number --no-heading --color=always --smart-case -- ''" \
        --bind "change:reload:sleep 0.1; rg --column --line-number --no-heading --color=always --smart-case -- {q} || true" \
        --delimiter : \
        --preview 'bat --color=always --style=numbers --highlight-line {2} {1}' \
        --preview-window 'right,60%,border-bottom,+{2}+3/3' \
        --bind 'enter:become(nvim {1} +{2})'
end
# uv
fish_add_path "/home/shiro/.local/bin"
