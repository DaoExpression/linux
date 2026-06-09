" default settings 
function! ReadOnly()
  return (&readonly || !&modifiable) ? 'Read Only ' : ''
endfunction
function! Modified()
  return (&modified) ? 'Modified' : 'Not modified'
endfunction
let g:currentmode={
      \ 'n'  : 'Normal',
      \ 'no' : 'N·Operator Pending',
      \ 'v'  : 'Visual',
      \ 'V'  : 'V·Line',
      \ '' : 'V·Block',
      \ 's'  : 'Select',
      \ 'S'  : 'S·Line',
      \ '^S' : 'S·Block',
      \ 'i'  : 'Insert',
      \ 'R'  : 'Replace',
      \ 'Rv' : 'VReplace',
      \ 'c'  : 'Command',
      \ 'cv' : 'Vim Ex',
      \ 'ce' : 'Ex',
      \ 'r'  : 'Prompt',
      \ 'rm' : 'More',
      \ 'r?' : 'Confirm',
      \ '!'  : 'Shell',
      \ 't'  : 'Terminal',
      \}
