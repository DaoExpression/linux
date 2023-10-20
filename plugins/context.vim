" https://github.com/wellle/context.vim
let g:context_enabled = 1
let g:context_max_height = 21
let g:context_max_per_indent = 5
let g:context_max_join_parts = 5
let g:context_border_char = '━'
let g:context_highlight_normal = 'Normal'
let g:context_highlight_border = 'Comment'
let g:context_highlight_tag    = 'Special'

let g:context_skip_regex = '^\s*\($\|#\|//\|/\*\|\*\($\|/s\|\/\)\)'
let g:context_extend_regex = '^\s*\([]{})]\|end\|else\|case\>\|default\>\)'
let g:context_join_regex = '^\W*$'
let g:Context_indent = { line -> [indent(line), indent(line)] }
let g:Context_border_indent = function('indent')
autocmd VimEnter     * ContextActivate
autocmd BufAdd       * call context#update('BufAdd')
autocmd BufEnter     * call context#update('BufEnter')
autocmd CursorMoved  * call context#update('CursorMoved')
autocmd VimResized   * call context#update('VimResized')
autocmd CursorHold   * call context#update('CursorHold')
autocmd User GitGutter call context#update('GitGutter')
autocmd OptionSet number,relativenumber,numberwidth,signcolumn,tabstop,list
            \          call context#update('OptionSet')

if exists('##WinScrolled')
    autocmd WinScrolled * call context#update('WinScrolled')
endif
