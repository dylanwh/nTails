# Cross-build from macOS or Linux (see shell.nix):
#   meson setup build --cross-file cross/mingw64.ini
#   meson compile -C build          # wintails.exe, ntailsd.exe
#   meson compile -C build msi      # wintails.msi via wixl
# Or natively in the MSYS2 mingw64 shell with
# mingw-w64-x86_64-{gcc,meson,ninja,pkgconf}; the msi target then needs wixl.
project('wintails', 'c', 'cpp',
  version: '0.3.0',
  meson_version: '>= 1.1',
  default_options: ['cpp_std=c++20', 'warning_level=2', 'buildtype=release',
                    'default_library=static'])

if host_machine.system() != 'windows'
  error('wintails is a Win32 program; use cross/mingw64.ini or the MSYS2 mingw64 shell')
endif

cpp = meson.get_compiler('cpp')
windows = import('windows')

# Both from WrapDB subprojects, linked statically, so the exe ships alone.
jansson = dependency('jansson', static: true)
qrencode = dependency('libqrencode', static: true)
win_libs = []
foreach lib : ['comctl32', 'comdlg32', 'wininet', 'shell32', 'advapi32']
  win_libs += cpp.find_library(lib)
endforeach

resources = windows.compile_resources('wintails.rc',
  depend_files: 'wintails.manifest',
  include_directories: include_directories('.'))

wintails = executable('wintails',
  'main.cpp',
  'rpc_client.cpp',
  'dialogs.cpp',
  'signin_dialog.cpp',
  'settings_dialog.cpp',
  'modal.cpp',
  'ssh_config.cpp',
  'system_proxy.cpp',
  'first_run.cpp',
  resources,
  cpp_args: ['-municode'],
  link_args: ['-municode', '-static'],
  dependencies: [jansson, qrencode] + win_libs,
  win_subsystem: 'windows')

# Go tracks its own staleness, so this always runs.
go = find_program('go')
ntailsd = custom_target('ntailsd',
  output: 'ntailsd.exe',
  command: [go, 'build', '-C', meson.project_source_root() / '..' / 'ntailsd',
            '-trimpath', '-ldflags', '-s -w -X main.version=' + get_option('tag'),
            '-o', meson.current_build_dir() / 'ntailsd.exe', '.'],
  env: {'CGO_ENABLED': '0', 'GOOS': 'windows', 'GOARCH': 'amd64'},
  build_always_stale: true,
  build_by_default: true)

wixl = find_program('wixl', required: false)
if wixl.found()
  msi = custom_target('wintails.msi',
    input: 'installer/Product.wxs',
    output: 'wintails.msi',
    command: [wixl, '-a', 'x64',
              '-D', 'DistDir=' + meson.current_build_dir(),
              '-D', 'Version=' + get_option('version'),
              '-o', '@OUTPUT@', '@INPUT@'],
    depends: [wintails, ntailsd])
  alias_target('msi', msi)
else
  message('wixl (msitools) not found; the msi target is unavailable')
endif
