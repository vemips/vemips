#include "pch.hpp"

#include "jit1.hpp"
#include "../../processor.hpp"
#include "coprocessor/coprocessor1/coprocessor1.hpp"
#include "instructions/instructions.hpp"
#include "instructions/instructions_common.hpp"
#include "instructions/instructions_table.hpp"
#include "instructions/coprocessor1_support.hpp"
#include <cassert>
#include "codegen.hpp"

using namespace mips;

extern jit1::jit_instructionexec_t jit1_get_instruction(jit1 * __restrict _this, uint32 address);
static constexpr uint32 MaxShortJumpLookAhead = 2;

bool Jit1_CodeGen::write_delay_branch(bool &terminate_instruction, jit1::ChunkOffset & __restrict chunk_offset, uint32 address, instruction_t instruction, const mips::instructions::InstructionInfo & __restrict instruction_info)
{
	const uint32 this_address = address;

	const uint32 chunk_begin = this_address & ~(jit1::ChunkSize - 1);
	const uint32 chunk_last = chunk_begin + (jit1::ChunkSize - 1);
	const uint32 next_chunk = chunk_last + 1;
	const uint32 this_offset = (this_address - chunk_begin) / 4u;

	static const int8 flags_offset = value_assert<int8>(offsetof(processor, flags_) - 128);
	static const int8 dbt_offset =  value_assert<int8>(offsetof(processor, branch_target_) - 128);
	static const int8 pc_offset = value_assert<int8>(offsetof(processor, program_counter_) - 128);
	static const int8 ic_offset = value_assert<int8>(offsetof(processor, instruction_count_) - 128);
	static const int8 gp_offset = value_assert<int8>(offsetof(processor, registers_) - 128);
	static const int8 r31 = gp_offset + (31 * 4);

	const Xbyak::Label no_jump;

	if (IS_INSTRUCTION(instruction_info, COP1_BC1EQZ_v))
	{
		static const int16 fp_offset = value_assert<int16>(offsetof(coprocessor1, m_registers) - 128);
		const instructions::FPRegister<16, 5> ft(instruction, (mips::coprocessor1 & __restrict)*jit_.processor_.get_coprocessor(1));
		const int16 ft_offset = value_assert<int16>(fp_offset + (8 * ft.get_register()));

		const int32 offset = instructions::TinyInt<18>(instruction << 2U).sextend<int32>();

		const uint32 target_address = address + 4 + offset;

		test(dword[r12 + ft_offset], 1); // ZF set to 1 if [ft] & 1 == 0
		jnz(no_jump);
		mov(esi, int32(target_address));
		or_(ebx, processor::flag::branch_delay);
		L(no_jump);
		if (!jit_.processor_.disable_cti_) {
			or_(ebx, processor::flag::no_cti);
		}
	}
	else if (IS_INSTRUCTION(instruction_info, COP1_BC1NEZ_v))
	{
		static const int16 fp_offset = value_assert<int16>(offsetof(coprocessor1, m_registers) - 128);
		const instructions::FPRegister<16, 5> ft(instruction, (mips::coprocessor1 & __restrict)*jit_.processor_.get_coprocessor(1));
		const int16 ft_offset = value_assert<int16>(fp_offset + (8 * ft.get_register()));

		const int32 offset = instructions::TinyInt<18>(instruction << 2U).sextend<int32>();

		const uint32 target_address = address + 4 + offset;

		test(dword[r12 + ft_offset], 1); // ZF set to 1 if [ft] & 1 == 0
		jz(no_jump);
		mov(esi, int32(target_address));
		or_(ebx, processor::flag::branch_delay);
		L(no_jump);
		if (!jit_.processor_.disable_cti_) {
			or_(ebx, processor::flag::no_cti);
		}
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_BAL))
	{
		const int32 immediate = instructions::TinyInt<18>(instruction << 2).sextend<int32>();

		const uint32 target_address = address + 4 + immediate;
		const uint32 link_address = address + 8;

		mov(dword[rbp + r31], int32(link_address));
		mov(esi, int32(target_address));
		or_(ebx, processor::flag::branch_delay);
		if (!jit_.processor_.disable_cti_) {
			or_(ebx, processor::flag::no_cti);
		}
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_BEQ))
	{
		const instructions::GPRegister<21, 5> rs(instruction, jit_.processor_);
		const instructions::GPRegister<16, 5> rt(instruction, jit_.processor_);
		const int32 immediate = instructions::TinyInt<18>(instruction << 2).sextend<int32>();

		const int8 rs_offset = value_assert<int8>(gp_offset + (4 * rs.get_register()));
		const int8 rt_offset = value_assert<int8>(gp_offset + (4 * rt.get_register()));

		const uint32 target_address = address + 4 + immediate;

		if (rs.get_register() == rt.get_register())
		{
			mov(esi, int32(target_address)); // 0 == 0
			or_(ebx, processor::flag::branch_delay | processor::flag::no_cti);
		}
		else
		{
			if (rs.get_register() == 0)
			{
				cmp(get_register_op32(rt), 0);
			}
			else if (rt.get_register() == 0)
			{
				cmp(get_register_op32(rs), 0);
			}
			else
			{
				mov(eax, get_register_op32(rs));
				cmp(eax, get_register_op32(rt));
			}
			jne(no_jump);
			mov(esi, int32(target_address));
			or_(ebx, processor::flag::branch_delay);
			L(no_jump);
			if (!jit_.processor_.disable_cti_) {
				or_(ebx, processor::flag::no_cti);
			}
		}
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_BGEZ))
	{
		const instructions::GPRegister<21, 5> rs(instruction, jit_.processor_);
		const int32 immediate = instructions::TinyInt<18>(instruction << 2).sextend<int32>();

		const int8 rs_offset = value_assert<int8>(gp_offset + (4 * rs.get_register()));

		const uint32 target_address = address + 4 + immediate;

		if (rs.get_register() == 0) // 0 >= 0
		{
			mov(esi, int32(target_address));
			or_(ebx, processor::flag::branch_delay | processor::flag::no_cti);
		}
		else
		{
			cmp(get_register_op32(rs), 0);
			jl(no_jump);
			mov(esi, int32(target_address));
			or_(ebx, processor::flag::branch_delay);
			L(no_jump);
			if (!jit_.processor_.disable_cti_) {
				or_(ebx, processor::flag::no_cti);
			}
		}
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_BGTZ))
	{
		const instructions::GPRegister<21, 5> rs(instruction, jit_.processor_);
		const int32 immediate = instructions::TinyInt<18>(instruction << 2).sextend<int32>();

		const int8 rs_offset = value_assert<int8>(gp_offset + (4 * rs.get_register()));

		const uint32 target_address = address + 4 + immediate;

		if (rs.get_register() == 0) // 0 !> 0
		{
			//nop
		}
		else
		{
			cmp(get_register_op32(rs), 0);
			jle(no_jump);
			mov(esi, int32(target_address));
			or_(ebx, processor::flag::branch_delay);
			L(no_jump);
		}
		if (!jit_.processor_.disable_cti_) {
			or_(ebx, processor::flag::no_cti);
		}
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_BLEZ))
	{
		const instructions::GPRegister<21, 5> rs(instruction, jit_.processor_);
		const int32 immediate = instructions::TinyInt<18>(instruction << 2).sextend<int32>();

		const int8 rs_offset = value_assert<int8>(gp_offset + (4 * rs.get_register()));

		const uint32 target_address = address + 4 + immediate;

		if (rs.get_register() == 0) // 0 <= 0
		{
			mov(esi, int32(target_address));
			or_(ebx, processor::flag::branch_delay | processor::flag::no_cti);
		}
		else
		{
			cmp(get_register_op32(rs), 0);
			jg(no_jump);
			mov(esi, int32(target_address));
			or_(ebx, processor::flag::branch_delay);
			L(no_jump);
			if (!jit_.processor_.disable_cti_) {
				or_(ebx, processor::flag::no_cti);
			}
		}
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_BLTZ))
	{
		const instructions::GPRegister<21, 5> rs(instruction, jit_.processor_);
		const int32 immediate = instructions::TinyInt<18>(instruction << 2).sextend<int32>();

		const int8 rs_offset = value_assert<int8>(gp_offset + (4 * rs.get_register()));

		const uint32 target_address = address + 4 + immediate;

		if (rs.get_register() == 0) // 0 !< 0
		{
			//nop
		}
		else
		{
			cmp(get_register_op32(rs), 0);
			jge(no_jump);
			mov(esi, int32(target_address));
			or_(ebx, processor::flag::branch_delay);
			L(no_jump);
		}
		if (!jit_.processor_.disable_cti_) {
			or_(ebx, processor::flag::no_cti);
		}
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_BNE))
	{
		const instructions::GPRegister<21, 5> rs(instruction, jit_.processor_);
		const instructions::GPRegister<16, 5> rt(instruction, jit_.processor_);
		const int32 immediate = instructions::TinyInt<18>(instruction << 2).sextend<int32>();

		const int8 rs_offset = value_assert<int8>(gp_offset + (4 * rs.get_register()));
		const int8 rt_offset = value_assert<int8>(gp_offset + (4 * rt.get_register()));

		const uint32 target_address = address + 4 + immediate;

		if (rs.get_register() == rt.get_register())
		{
			//nop
		}
		else
		{
			if (rs.get_register() == 0)
			{
				cmp(get_register_op32(rt), 0);
			}
			else if (rt.get_register() == 0)
			{
				cmp(get_register_op32(rs), 0);
			}
			else
			{
				mov(eax, get_register_op32(rs));
				cmp(eax, get_register_op32(rt));
			}
			je(no_jump);
			mov(esi, int32(target_address));
			or_(ebx, processor::flag::branch_delay);
			L(no_jump);
		}
		if (!jit_.processor_.disable_cti_) {
			or_(ebx, processor::flag::no_cti);
		}
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_J))
	{
		const uint32 instr_index = instructions::TinyInt<28>(instruction << 2).zextend<uint32>();

		const uint32 target_address = (address & instructions::HighBits(4)) | instr_index;

		mov(esi, int32(target_address));
		or_(ebx, processor::flag::branch_delay | processor::flag::no_cti);
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_JAL))
	{
		const uint32 instr_index = instructions::TinyInt<28>(instruction << 2).zextend<uint32>();

		const uint32 target_address = (address & instructions::HighBits(4)) | instr_index;

		const uint32 link_address = address + 8;

		mov(dword[rbp + r31], int32(link_address));
		mov(esi, int32(target_address));
		or_(ebx, processor::flag::branch_delay | processor::flag::no_cti);
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_JALR))
	{
		const instructions::GPRegister<21, 5> rs(instruction, jit_.processor_);
		const instructions::GPRegister<11, 5> rd(instruction, jit_.processor_);

		const uint32 link_address = address + 8;

		if (rd.get_register() != 0)
		{
			mov(dword[rbp + (int64(gp_offset) + int64(rd.get_register()) * 4)], int32(link_address));
		}
		mov(esi, dword[rbp + (gp_offset + int64(rs.get_register()) * 4)]);
		or_(ebx, processor::flag::branch_delay | processor::flag::no_cti);
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_JR))
	{
		const instructions::GPRegister<21, 5> rs(instruction, jit_.processor_);
		const instructions::GPRegister<11, 5> rd(instruction, jit_.processor_);

		mov(esi, dword[rbp + (int64(gp_offset) + int64(rs.get_register()) * 4)]);
		or_(ebx, processor::flag::branch_delay | processor::flag::no_cti);
	}
	else
	{
		xwarn(false, "delay branch implementation missing");
		insert_procedure_ecx(address, uint64(instruction_info.Proc), instruction, instruction_info);
		return true;
	}

	return false;
}

// enum class branch_type : uint32
// {
//	 near_branch = 0,		  // Branches within this chunk			
//	 far_branch,				 // Branches outside this chunk
//	 indeterminate			  // Branches to an unknown location
// };
void Jit1_CodeGen::handle_delay_branch(jit1::Chunk & __restrict chunk, jit1::ChunkOffset & __restrict chunk_offset, uint32 address, instruction_t instruction, const mips::instructions::InstructionInfo & __restrict instruction_info)
{
	branch_type branch_type;
	uint32 target_address = 0;

	const uint32 this_address = address + 4;

	const uint32 chunk_begin = this_address & ~(jit1::ChunkSize - 1);
	const uint32 chunk_last = chunk_begin + (jit1::ChunkSize - 1);
	const uint32 next_chunk = chunk_last + 1;
	const uint32 this_offset = (this_address - chunk_begin) / 4u;

	static const int8 flags_offset = value_assert<int8>(offsetof(processor, flags_) - 128);
	static const int8 dbt_offset =  value_assert<int8>(offsetof(processor, branch_target_) - 128);
	static const int8 pc_offset = value_assert<int8>(offsetof(processor, program_counter_) - 128);
	static const int8 ic_offset = value_assert<int8>(offsetof(processor, instruction_count_) - 128);
	static const int8 gp_offset = value_assert<int8>(offsetof(processor, registers_) - 128);
	static const int8 r31 = gp_offset + int8(31 * 4);

	const auto patch_preprolog = [&](auto address) -> Xbyak::Label
	{
		// If execution gets past the chunk, we jump to the next chunk.
		// Start with a set of nops so that we have somewhere to write patch code.
		const auto patch = L(); // patch should be 12 bytes. Enough to copy an 8B pointer to rax, and then to jump to it.
		chunk.m_patches.push_back({ uint32(getSize()), 0 });
		auto & [offset, target] = chunk.m_patches.back();
		uint32 &patch_target = target;

		// patch no-op
		if (address == nullptr) {
			db(0x66, 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x1F, 0x00);
		}
		else {
			static constexpr uint16 patch_prefix = 0xB848;
			static constexpr uint16 patch_suffix = 0xE0FF;
			dw(patch_prefix);
			dq(uint64(address));
			dw(patch_suffix);
		}

		mov(rcx, int64(&patch_target));
		mov(dword[rcx], edx);

		return patch;
	};

	const auto patch_prolog = [&]()
	{
		auto &patch_pair = chunk.m_patches.back();
		uint32 &patch_target = patch_pair.target;
		mov(rcx, int64(&patch_target));
		mov(dword[rcx], edx);
	};

	const auto patch_epilog = [&](const Xbyak::Label &patch)
	{
		static constexpr uint16 patch_prefix = 0xB848;
		static constexpr uint16 patch_suffix = 0xE0FF;

		mov(rcx, patch);
		mov(word[rcx], int16_t(patch_prefix));
		mov(qword[rcx + 2], rax);
		mov(word[rcx + 10], int16_t(patch_suffix));
	};

	const auto safe_jmp = [&](const Xbyak::Label &target_label, const uint32 instruction_offset)
	{
		const LabelType label_type =
			((instruction_offset <= this_offset && (chunk_offset[this_offset] - chunk_offset[instruction_offset]) <= 128) || (instruction_offset - this_offset) <= MaxShortJumpLookAhead) ?
			T_AUTO :
			T_NEAR;

		jmp(target_label, label_type);
	};

	if (IS_INSTRUCTION(instruction_info, COP1_BC1EQZ_v))
	{
		const int32 offset = instructions::TinyInt<18>(instruction << 2U).sextend<int32>();
		target_address = address + 4 + offset;

		if (chunk_begin <= target_address && chunk_last >= target_address)
		{
			branch_type = branch_type::near_branch;
		}
		else
		{
			branch_type = branch_type::far_branch;
		}
	}
	else if (IS_INSTRUCTION(instruction_info, COP1_BC1NEZ_v))
	{
		const int32 offset = instructions::TinyInt<18>(instruction << 2U).sextend<int32>();
		target_address = address + 4 + offset;

		if (chunk_begin <= target_address && chunk_last >= target_address)
		{
			branch_type = branch_type::near_branch;
		}
		else
		{
			branch_type = branch_type::far_branch;
		}
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_BAL))
	{
		const int32 immediate = instructions::TinyInt<18>(instruction << 2).sextend<int32>();
		target_address = address + 4 + immediate;

		if (chunk_begin <= target_address && chunk_last >= target_address)
		{
			branch_type = branch_type::near_branch;
		}
		else
		{
			branch_type = branch_type::far_branch;
		}
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_BEQ))
	{
		const int32 immediate = instructions::TinyInt<18>(instruction << 2).sextend<int32>();
		target_address = address + 4 + immediate;

		if (chunk_begin <= target_address && chunk_last >= target_address)
		{
			branch_type = branch_type::near_branch;
		}
		else
		{
			branch_type = branch_type::far_branch;
		}
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_BGEZ))
	{
		const int32 immediate = instructions::TinyInt<18>(instruction << 2).sextend<int32>();
		target_address = address + 4 + immediate;

		if (chunk_begin <= target_address && chunk_last >= target_address)
		{
			branch_type = branch_type::near_branch;
		}
		else
		{
			branch_type = branch_type::far_branch;
		}
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_BGTZ))
	{
		const int32 offset = instructions::TinyInt<18>(instruction << 2).sextend<int32>();
		target_address = address + 4 + offset;

		if (chunk_begin <= target_address && chunk_last >= target_address)
		{
			branch_type = branch_type::near_branch;
		}
		else
		{
			branch_type = branch_type::far_branch;
		}
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_BLEZ))
	{
		const int32 offset = instructions::TinyInt<18>(instruction << 2).sextend<int32>();
		target_address = address + 4 + offset;

		if (chunk_begin <= target_address && chunk_last >= target_address)
		{
			branch_type = branch_type::near_branch;
		}
		else
		{
			branch_type = branch_type::far_branch;
		}
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_BLTZ))
	{
		const int32 offset = instructions::TinyInt<18>(instruction << 2).sextend<int32>();
		target_address = address + 4 + offset;

		if (chunk_begin <= target_address && chunk_last >= target_address)
		{
			branch_type = branch_type::near_branch;
		}
		else
		{
			branch_type = branch_type::far_branch;
		}
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_BNE))
	{
		const int32 offset = instructions::TinyInt<18>(instruction << 2).sextend<int32>();
		target_address = address + 4 + offset;

		if (chunk_begin <= target_address && chunk_last >= target_address)
		{
			branch_type = branch_type::near_branch;
		}
		else
		{
			branch_type = branch_type::far_branch;
		}
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_J))
	{
		const uint32 instr_index = instructions::TinyInt<28>(instruction << 2).zextend<uint32>();
		target_address =  (address & instructions::HighBits(4)) | instr_index;;

		if (chunk_begin <= target_address && chunk_last >= target_address)
		{
			branch_type = branch_type::near_branch;
		}
		else
		{
			branch_type = branch_type::far_branch;
		}
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_JAL))
	{
		const uint32 instr_index = instructions::TinyInt<28>(instruction << 2).zextend<uint32>();
		target_address =  (address & instructions::HighBits(4)) | instr_index;;

		if (chunk_begin <= target_address && chunk_last >= target_address)
		{
			branch_type = branch_type::near_branch;
		}
		else
		{
			branch_type = branch_type::far_branch;
		}
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_JALR))
	{
		const instructions::GPRegister<21, 5> rs(instruction, jit_.processor_);

		if (rs.get_register() != 0)
		{
			branch_type = branch_type::indeterminate;
		}
		else
		{
			target_address = 0;

			if (chunk_begin <= target_address && chunk_last >= target_address)
			{
				branch_type = branch_type::near_branch;
			}
			else
			{
				branch_type = branch_type::far_branch;
			}
		}
	}
	else if (IS_INSTRUCTION(instruction_info, PROC_JR))
	{
		const instructions::GPRegister<21, 5> rs(instruction, jit_.processor_);

		if (rs.get_register() != 0)
		{
			branch_type = branch_type::indeterminate;
		}
		else
		{
			target_address = 0;

			if (chunk_begin <= target_address && chunk_last >= target_address)
			{
				branch_type = branch_type::near_branch;
			}
			else
			{
				branch_type = branch_type::far_branch;
			}
		}
	}
	else
	{
		xwarn(false, "delay branch implementation missing");
		branch_type = branch_type::indeterminate_unhandled;
	}

	switch (branch_type)
	{
		case branch_type::near_branch:						// Branches within this chunk
		{
			const Xbyak::Label no_branch;
			test(ebx, processor::flag::branch_delay);
			je(no_branch);
			and_(ebx, ~processor::flag::branch_delay);
			// what is the offset of the target address?
			const uint32 target_offset = (target_address - chunk_begin) / 4u;
			const auto& target_label = get_instruction_offset_label(target_offset);
			xor_(esi, esi);
			safe_jmp(target_label, target_offset);
			L(no_branch);
		} break;
		case branch_type::far_branch:						 // Branches outside this chunk
		{
			const Xbyak::Label no_branch;
			test(ebx, processor::flag::branch_delay);
			je(no_branch);
			xor_(esi, esi);
			and_(ebx, ~processor::flag::branch_delay);
			const auto patch = patch_preprolog(jit_.fetch_instruction(target_address));

			mov(edx, int32(target_address));

			patch_prolog();

			mov(rax, uint64(jit1_get_instruction));
			mov(rcx, uint64(&jit_));
			call(rax);
			patch_epilog(patch);
			jmp(rax);

			L(no_branch);
		} break;
		case branch_type::indeterminate:					 // Branches to an unknown location
		{
			const Xbyak::Label no_branch;
			const Xbyak::Label not_within;

			test(ebx, processor::flag::branch_delay);
			je(no_branch);
			and_(ebx, ~processor::flag::branch_delay);
			mov(eax, esi);
			xor_(esi, esi);

			mov(ecx, eax);
			and_(ecx, ~(jit1::ChunkSize - 1));
			cmp(ecx, chunk_begin);
			jne(not_within);
			and_(eax, (jit1::ChunkSize - 1));

			mov(rcx, uint64(chunk_offset.data()));
			mov(eax, dword[rcx + rax]);
			mov(rcx, intrinsics_.chunk_start);
			add(rax, rcx);
			jmp(rax);
			L(not_within);
			mov(rdx, rax);
			mov(rax, uint64(jit1_get_instruction));
			mov(rcx, uint64(&jit_));
			call(rax);
			jmp(rax);
			L(no_branch);
		} break;
		case branch_type::near_branch_unhandled:		  // Branches within this chunk, use pc state	
		{
			const Xbyak::Label no_branch;
			test(ebx, processor::flag::branch_delay);
			jz(no_branch);
			and_(ebx, ~processor::flag::branch_delay);
			mov(eax, int32(target_address));
			mov(dword[rbp + pc_offset], eax);

			// what is the offset of the target address?
			const uint32 target_offset = (target_address - chunk_begin) / 4u;
			const auto& target_label = get_instruction_offset_label(target_offset);

			safe_jmp(target_label, target_offset);
			L(no_branch);
		} break;
		case branch_type::far_branch_unhandled:			// Branches outside this chunk, use pc state
		{
			const Xbyak::Label no_branch;
			test(ebx, processor::flag::branch_delay);
			jz(no_branch);
			and_(ebx, ~processor::flag::branch_delay);
			mov(eax, int32(target_address));
			mov(dword[rbp + pc_offset], eax);

			mov(rdx, rax);
			mov(rax, uint64(jit1_get_instruction));
			mov(rcx, uint64(&jit_));
			call(rax);
			jmp(rax);

			L(no_branch);
		} break;
		case branch_type::indeterminate_unhandled:		// Branches to an unknown location, use pc state
		{
			const Xbyak::Label no_branch;
			const Xbyak::Label not_within;

			test(ebx, processor::flag::branch_delay);
			jz(no_branch);
			and_(ebx, ~processor::flag::branch_delay);
			mov(eax, dword[rbp + dbt_offset]);
			mov(dword[rbp + pc_offset], eax);

			mov(ecx, eax);
			and_(ecx, ~(jit1::ChunkSize - 1));
			cmp(ecx, chunk_begin);
			jne(not_within);
			and_(eax, (jit1::ChunkSize - 1));

			mov(rcx, uint64(chunk_offset.data()));
			mov(eax, dword[rcx + rax]);
			mov(rcx, intrinsics_.chunk_start);
			add(rax, rcx);
			jmp(rax);
			L(not_within);
			mov(rdx, rax);
			mov(rax, uint64(jit1_get_instruction));
			mov(rcx, uint64(&jit_));
			call(rax);
			jmp(rax);
			L(no_branch);
		} break;
	}
}
