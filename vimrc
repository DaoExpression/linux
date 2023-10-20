" General options
set nocompatible " We use Vim, not Vi
syntax enable " Enable syntax highlights
set ttyfast " Faster refraw
set mouse=nv " Mouse activated in Normal and Visual Mode
set shortmess+=I " No intro when starting Vim
set smartindent " Smart... indent
set expandtab " Insert spaces instead of tabs
set softtabstop=2 " ... and insert two spaces
set shiftwidth=2 " Indent with two spaces
set incsearch " Search as typing
set hlsearch " Highlight search results
set cursorline " Highligt the cursor line
set showmatch " When a bracket is inserted, briefly jump to the matching one
set matchtime=3 " ... during this time
set virtualedit=onemore " Allow the cursor to move just past the end of the line
set history=100 " Keep 100 undo
set wildmenu " Better command-line completion
set scrolloff=10 " Always keep 10 lines after or before when scrolling
set sidescrolloff=5 " Always keep 5 lines after or before when side scrolling
set noshowmode " Don't display the current mode
set gdefault " The substitute flag g is on
set hidden " Hide the buffer instead of closing when switching
set backspace=indent,eol,start " The normal behaviour of backspace
set showtabline=2 " Always show tabs
set laststatus=2 " Always show status bar
set number " Show the line number
set updatetime=1000
set ignorecase " Search insensitive
set smartcase " ... but smart
let &showbreak="\u21aa " " Show a left arrow when wrapping text
set encoding=utf-8  " The encoding displayed.
set fileencoding=utf-8  " The encoding written to file.
set synmaxcol=300 " Don't try to highlight long lines
"set guioptions-=T " Don't show toolbar in Gvim
set iskeyword+=\- " Complete words containing a dash
set title
set shortmess+=c
set titleold="Terminal"
" Speed up the redraw
au CursorHold * let &ro = &ro
" Open all cmd args in new tabs
execute ":silent tab all"

" Load Plugins using plug
source ~/.vim/plugins/loadPlugins.vim
" Plugins configs
source ~/.vim/plugins/coc.vim
source ~/.vim/plugins/wiki.vim
source ~/.vim/plugins/bookmarks.vim
source ~/.vim/plugins/theme.vim
"source ~/.vim/plugins/fzf.vim
"source ~/.vim/plugins/pad.vim
" Vim configs
source ~/.vim/configs/functions.vim
source ~/.vim/configs/syntaxColors.vim
source ~/.vim/configs/backups.vim
source ~/.vim/configs/default.vim
source ~/.vim/configs/tabConfig.vim
source ~/.vim/configs/utils.vim
source ~/.vim/configs/shortcuts.vim
source ~/.vim/configs/comments.vim
source ~/.vim/configs/explorer.vim
source ~/.vim/configs/lag.vim

augroup toggleCocExtensions
    autocmd!
    autocmd BufEnter *.md call CocActionAsync('deactivateExtension', 'coc-tag')
    autocmd BufLeave *.md call CocActionAsync('activeExtension', 'coc-tag')
augroup END

autocmd VimEnter * exe "CocDisable"
autocmd VimEnter *.html exe "CocEnable" 
autocmd VimEnter *.css exe "CocEnable" 
autocmd VimEnter *.js exe "CocEnable" 


let g:coc_start_at_startup=0
nmap <leader>cc :<C-u>CocStart<CR>
let g:coc_global_extensions = [
    \ 'coc-vimlsp'
    \ ]

if has('vim')
  call coc#rpc#stop()
endif

