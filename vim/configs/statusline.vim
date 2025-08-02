" Personal status line 
" very minimal but enough
set statusline=
set statusline+=%1*\ ***%{toupper(g:currentmode[mode()])}***\  " Current mode
set statusline+=%2*\ %<%F\  " Filepath
set statusline+=%2*\ %= " To the right
set statusline+=%2*\ (%{&filetype}) " Filetype
set statusline+=%2*\ %{toupper((&fenc!=''?&fenc:&enc))}\[%{&ff}] " Encoding & Fileformat
set statusline+=%2*\ %{Modified()} " Modified Flags
set statusline+=%2*\ %{ReadOnly()} " ReadOnly Flags
set statusline+=%1*\ \%l/%L(%P)-%c\  " Position
