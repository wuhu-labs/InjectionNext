#include <assert.h>
#include <unistd.h>
#include "../../Sources/InjectionNextC/fishhook.c"

void *fast_dlsym(const void *ptr, const char *name) { return NULL; }

int main(void) {
  size_t page = getpagesize();
  void *memory = mmap(NULL, page, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANON, -1, 0);
  assert(memory != MAP_FAILED);
  void **bindings = (void **)((char *)memory + sizeof(void *));
  bindings[0] = (void *)0x1234;
  assert(mprotect(memory, page, PROT_READ) == 0);
  section_t section = {0};
  strcpy(section.segname, SEG_DATA_CONST);
  section.addr = (uintptr_t)bindings;
  section.size = sizeof(void *);
  nlist_t symbols[1] = {0};
  symbols[0].n_un.n_strx = 1;
  uint32_t indices[1] = {0};
  char names[] = "\0_fixture";
  void *old = NULL;
  struct rebinding rebinding = {"fixture", (void *)0x5678, &old};
  struct rebindings_entry entry = {&rebinding, 1, NULL};
  perform_rebinding_with_section(&entry, &section, 0, symbols, names, indices);
  assert(old == (void *)0x1234);
  assert(bindings[0] == (void *)0x5678);
  assert((get_protection(bindings) & VM_PROT_WRITE) == 0);
  assert(munmap(memory, page) == 0);
  puts("fishhook: read-only unaligned section rebound and original protection restored");
}
