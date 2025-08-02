" Install all Plugins Plugins
" Plug control - single file 
call plug#begin()
  " Colors for the editor
  Plug 'ap/vim-css-color'
  " Select and change several at once
  Plug 'mg979/vim-visual-multi'
  " Resize splits
  Plug 'simeji/winresizer'
  " Calendar and Todo Utils
  Plug 'itchyny/calendar.vim'
  " Wiki for vim
  Plug 'lervag/wiki.vim'
  " Use release branch (recommended)
  Plug 'neoclide/coc.nvim', {'branch': 'release'}
  "  One Dark Theme 
  Plug 'joshdick/onedark.vim'
  " Tag bar 
  Plug 'preservim/tagbar'
  " Android IDE 
  " Plug 'hsanson/vim-android'
  " Git + Tig 
  " Plug 'tpope/vim-fugitive'
  " Plug 'rbong/vim-flog'
  " File Picker
  Plug 'srstevenson/vim-picker'
  " suround
  Plug 'yaocccc/vim-surround'
  " Vista Tags 
  Plug 'liuchengxu/vista.vim'
  " FZF - Find and edit
  " Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
  " Plug 'yuki-yano/fzf-preview.vim', { 'branch': 'release/rpc' }
call plug#end()
