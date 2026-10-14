#include <assert.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_region.h>

static int failed_lookup;
static int failed_protect_call;
static int protect_calls;

static kern_return_t fixture_region(vm_map_t task, vm_address_t *address,
    vm_size_t *size, vm_region_flavor_t flavor, vm_region_info_t info,
    mach_msg_type_number_t *count, mach_port_t *object) {
  if (failed_lookup) return KERN_FAILURE;
  return vm_region_64(task, address, size, flavor, info, count, object);
}

static kern_return_t fixture_protect(vm_map_t task, vm_address_t address,
    vm_size_t size, boolean_t maximum, vm_prot_t protection) {
  if (++protect_calls == failed_protect_call) return KERN_FAILURE;
  return vm_protect(task, address, size, maximum, protection);
}

#define vm_region_64 fixture_region
#define vm_protect fixture_protect
#include "../../Sources/InjectionNextC/fishhook.c"
#undef vm_region_64
#undef vm_protect

void *fast_dlsym(const void *ptr, const char *name) { return NULL; }

static void exercise(int lookup_failure, int protection_failure) {
  failed_lookup = lookup_failure;
  failed_protect_call = protection_failure;
  protect_calls = 0;
  fishhook_reset_protection_error();
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
  int result = perform_rebinding_with_section(&entry, &section, 0, symbols, names, indices);
  if (lookup_failure || protection_failure == 1) {
    assert(result == -1);
    assert(old == NULL && bindings[0] == (void *)0x1234);
  } else {
    assert(old == (void *)0x1234 && bindings[0] == (void *)0x5678);
    assert(result == (protection_failure == 2 ? -1 : 0));
  }
  const char *error = fishhook_protection_error();
  if (lookup_failure) assert(error && strstr(error, "region lookup failed"));
  else if (protection_failure == 1) assert(error && strstr(error, "write protection failed"));
  else if (protection_failure == 2) assert(error && strstr(error, "restore failed"));
  else assert(error == NULL);
  failed_lookup = 0;
  vm_prot_t protection;
  assert(get_protection(bindings, &protection));
  assert(((protection & VM_PROT_WRITE) != 0) == (protection_failure == 2));
  assert(munmap(memory, page) == 0);
}

int main(void) {
  exercise(0, 0);
  exercise(1, 0);
  exercise(0, 1);
  exercise(0, 2);
  fishhook_reset_protection_error();
  assert(fishhook_protection_error() == NULL);
  puts("fishhook: protected rebinding and injected lookup/write/restore failures passed");
}
