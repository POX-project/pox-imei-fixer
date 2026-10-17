obj-m += md_patcher.o

# The prebuilt md_patcher.ko was linked without the stack protector, so the
# module had no __stack_chk_* dependency.  Match that (harmless either way, the
# kernel does export the guard, but this keeps the import set identical).
ccflags-y += -fno-stack-protector
