// SPDX-License-Identifier: GPL-2.0
/*
 * md_patcher - Modem (MD) image RSA modulus patcher for aftermarket IMEI support.
 *
 * Clean-room reimplementation of the prebuilt vendor module md_patcher.ko
 * (author timjosten, version 2.31, vermagic 4.14.186-g215472d).  The original
 * source was never published; this file reproduces its behaviour from the
 * disassembly of the shipped .ko.
 *
 *   1. Dump the EMI MPU region table through the MTK secure monitor
 *      (SIP id 0xc2000261 = MTK_SIP_KERNEL_EMIMPU_READ) and locate the modem
 *      region, logging it as "md image base".
 *   2. Map that region: vmap() over struct page * for normal RAM, otherwise
 *      __ioremap().  The page array is built with pfn_to_page(), which on
 *      arm64 expands to VMEMMAP_START + (phys >> 6) - (memstart_addr >> 6),
 *      exactly the arithmetic the original open-coded.
 *   3. Scan for the stock modem RSA modulus 256 bytes at a 4 byte stride and,
 *      when found, lift the EMI MPU protection on the region and overwrite the
 *      modulus with the patched one.
 *   4. Always return -25 (matching the original) so this one-shot module is
 *      unloaded immediately after init.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/mm.h>
#include <linux/vmalloc.h>
#include <linux/io.h>
#include <linux/string.h>

#include "modulus.h"

#define MD_DRAM_OFFSET		0x40000000ULL
#define MD_EMI_MPU_SA_BASE	0x100U
#define MD_EMI_MPU_EA_BASE	0x200U
#define MD_EMI_MPU_APC_BASE	0x300U
#define MD_EMI_MPU_REGION_NUM	32

#define MD_SIP_EMIMPU_READ	0xc2000261UL

#define MD_REGION_MIN_SIZE	0x10001ULL
#define MD_REGION_MIN_START	0x40000001ULL

#define MD_RSA_MODULUS_SIZE	256
#define MD_SEARCH_STRIDE	4

#define MD_INIT_RET		(-25)

struct md_emi_region_info {
	unsigned long long start;
	unsigned long long end;
	unsigned int region;
	unsigned int apc[2];
};

extern int emi_mpu_set_protection(struct md_emi_region_info *region_info);

static unsigned long MDADDR;
static unsigned long MDSIZE;
static unsigned int REGION = 10;

static const char * const md_permission[] = {
	"No", "S_RW", "S_RW_NS_R", "S_RW_NS_W",
	"S_R_NS_R", "FORBIDDEN", "S_R_NS_RW", "NONE",
};

static noinline unsigned long md_secure_call(unsigned long fn, unsigned long a0,
					     unsigned long a1, unsigned long a2,
					     unsigned long a3)
{
	register unsigned long x0 asm("x0") = fn;
	register unsigned long x1 asm("x1") = a0;
	register unsigned long x2 asm("x2") = a1;
	register unsigned long x3 asm("x3") = a2;
	register unsigned long x4 asm("x4") = a3;

	asm volatile("smc #0\n"
		     : "+r" (x0), "+r" (x1), "+r" (x2), "+r" (x3), "+r" (x4)
		     :
		     : "memory");

	return x0;
}

static void md_mpu_config_dump(int region)
{
	int r;

	for (r = 0; r < MD_EMI_MPU_REGION_NUM; r++) {
		unsigned long off = r * 4;
		unsigned long sa, ea, apc;
		unsigned long long start, end, size;

		if (region >= 0 && (unsigned long)(region * 4) != off)
			continue;

		sa = md_secure_call(MD_SIP_EMIMPU_READ,
				    MD_EMI_MPU_SA_BASE + off, 0, 0, 0);
		start = MD_DRAM_OFFSET + (sa << 16);

		ea = md_secure_call(MD_SIP_EMIMPU_READ,
				    MD_EMI_MPU_EA_BASE + off, 0, 0, 0);
		end = (MD_DRAM_OFFSET + 0xffff) + (ea << 16);

		size = end - start + 1;

		if (MDADDR == 0 && size >= MD_REGION_MIN_SIZE &&
		    start >= MD_REGION_MIN_START && r > (int)REGION) {
			MDADDR = start;
			MDSIZE = size;
			REGION = r - 1;
		}

		pr_info("md_patcher: R%d-> 0x%llx to 0x%llx, size 0x%llx\n",
			r, start, end, size);

		apc = md_secure_call(MD_SIP_EMIMPU_READ,
				     MD_EMI_MPU_APC_BASE + off, 0, 0, 0);
		pr_info("md_patcher: %s, %s, %s, %s, %s, %s, %s, %s\n",
			md_permission[apc & 7], md_permission[(apc >> 3) & 7],
			md_permission[(apc >> 6) & 7], md_permission[(apc >> 9) & 7],
			md_permission[(apc >> 12) & 7], md_permission[(apc >> 15) & 7],
			md_permission[(apc >> 18) & 7], md_permission[(apc >> 21) & 7]);
	}
}

static int __init md_patcher_init(void)
{
	void *base;
	unsigned char *p, *end, *found = NULL;
	unsigned long count, i;

	md_mpu_config_dump(-1);

	if ((MDADDR >> 30) == 0 || (MDSIZE >> 24) == 0)
		return MD_INIT_RET;

	pr_info("md_patcher: md image base 0x%llx, size 0x%llx\n",
		(unsigned long long)MDADDR, (unsigned long long)MDSIZE);

	count = (MDSIZE + PAGE_SIZE - 1) >> PAGE_SHIFT;

	if (pfn_valid(MDADDR >> PAGE_SHIFT)) {
		struct page **pages;
		unsigned long pfn = MDADDR >> PAGE_SHIFT;

		pages = vmalloc(count * sizeof(*pages));
		if (!pages)
			return MD_INIT_RET;

		for (i = 0; i < count; i++)
			pages[i] = pfn_to_page(pfn++);

		base = vmap(pages, count, VM_MAP, PAGE_KERNEL);
		vfree(pages);
		if (!base)
			return MD_INIT_RET;
	} else {
		base = __ioremap(MDADDR & PAGE_MASK, MDSIZE, PAGE_KERNEL);
		if (!base)
			return MD_INIT_RET;
	}

	end = base + MDSIZE - MD_RSA_MODULUS_SIZE;
	for (p = base; p < end; p += MD_SEARCH_STRIDE) {
		if (memcmp(p, modem_rsa_modulus, MD_RSA_MODULUS_SIZE) == 0) {
			found = p;
			break;
		}
	}

	if (found) {
		struct md_emi_region_info info;

		pr_info("md_patcher: modulus ptr 0x%llx\n",
			(unsigned long long)found);
		pr_info("md_patcher: modulus before 0x%x\n", *(u32 *)found);

		info.start = MDADDR;
		info.end = MDADDR + MDSIZE - 1;
		info.region = REGION;
		info.apc[0] = 0;
		info.apc[1] = 0;
		emi_mpu_set_protection(&info);

		md_mpu_config_dump(REGION);

		memcpy(found, patched_rsa_modulus, MD_RSA_MODULUS_SIZE);
		pr_info("md_patcher: modulus after 0x%x\n",
			*(u32 *)patched_rsa_modulus);
	}

	__iounmap(base);

	return MD_INIT_RET;
}

static void __exit md_patcher_exit(void)
{
}

module_init(md_patcher_init);
module_exit(md_patcher_exit);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("timjosten");
MODULE_DESCRIPTION("Modem patcher for aftermarket IMEI");
MODULE_VERSION("2.31");
