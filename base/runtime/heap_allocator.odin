package runtime

import "base:intrinsics"

heap_allocator :: proc() -> Allocator {
	return Allocator{
		procedure = heap_allocator_proc,
		data = nil,
	}
}

heap_allocator_proc :: proc(allocator_data: rawptr, mode: Allocator_Mode,
                            size, alignment: int,
                            old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, Allocator_Error) {
	//
	// NOTE(tetra, 2020-01-14): The heap doesn't respect alignment.
	// Instead, we overallocate by `alignment + size_of(rawptr) - 1`, and insert
	// padding. We also store the original pointer returned by heap_alloc right before
	// the pointer we return to the user.
	//

	aligned_alloc :: proc(size, alignment: int, old_ptr: rawptr, old_size: int, zero_memory := true) -> ([]byte, Allocator_Error) {
		// Not(flysand): We need to reserve enough space for alignment, which
		// includes the user data itself, the space to store the pointer to
		// allocation start, as well as the padding required to align both
		// the user data and the pointer.
		a := max(alignment, align_of(rawptr))
		space := a-1 + size_of(rawptr) + size
		allocated_mem: rawptr

		force_copy := old_ptr != nil && alignment > align_of(rawptr)

		if old_ptr != nil && !force_copy {
			original_old_ptr := ([^]rawptr)(old_ptr)[-1]
			allocated_mem = heap_resize(original_old_ptr, space)
		} else {
			allocated_mem = heap_alloc(space, zero_memory)
		}
		aligned_mem := rawptr(([^]u8)(allocated_mem)[size_of(rawptr):])

		ptr := uintptr(aligned_mem)
		aligned_ptr := (ptr + uintptr(a)-1) & ~(uintptr(a)-1)
		if allocated_mem == nil {
			aligned_free(old_ptr)
			aligned_free(allocated_mem)
			return nil, .Out_Of_Memory
		}

		aligned_mem = rawptr(aligned_ptr)
		([^]rawptr)(aligned_mem)[-1] = allocated_mem

		if force_copy {
			mem_copy_non_overlapping(aligned_mem, old_ptr, min(old_size, size))
			aligned_free(old_ptr)
		}

		return byte_slice(aligned_mem, size), nil
	}

	aligned_free :: proc(p: rawptr) {
		if p != nil {
			heap_free(([^]rawptr)(p)[-1])
		}
	}

	aligned_resize :: proc(p: rawptr, old_size: int, new_size: int, new_alignment: int, zero_memory := true) -> (new_memory: []byte, err: Allocator_Error) {
		if p == nil {
			return aligned_alloc(new_size, new_alignment, nil, old_size, zero_memory)
		}

		new_memory = aligned_alloc(new_size, new_alignment, p, old_size, zero_memory) or_return

		// NOTE: heap_resize does not zero the new memory, so we do it
		if zero_memory && new_size > old_size {
			new_region := raw_data(new_memory[old_size:])
			intrinsics.mem_zero(new_region, new_size - old_size)
		}
		return
	}

	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		return aligned_alloc(size, alignment, nil, 0, mode == .Alloc)

	case .Free:
		aligned_free(old_memory)

	case .Free_All:
		return nil, .Mode_Not_Implemented

	case .Resize, .Resize_Non_Zeroed:
		return aligned_resize(old_memory, old_size, size, alignment, mode == .Resize)

	case .Query_Features:
		set := (^Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, nil

	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}

	return nil, nil
}


heap_alloc :: proc "contextless" (size: int, zero_memory := true) -> rawptr {
	return _heap_alloc(size, zero_memory)
}

heap_resize :: proc "contextless" (ptr: rawptr, new_size: int) -> rawptr {
	return _heap_resize(ptr, new_size)
}

heap_free :: proc "contextless" (ptr: rawptr) {
	_heap_free(ptr)
}