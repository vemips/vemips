require_relative 'platform.rb'

CCACHE_PATH = where_async?('ccache')

class KeyValue
	attr_accessor :key, :value

	def initialize(key, value)
		@key = key
		@value = value
	end
end

module ToolchainProto
	def define_tool(mod, name, value, raw: false)
		return nil if ALTERNATE_COMPILER_SETTING

		value_key = value
		value = mod.evaluate(value)

		args = nil
		if value.instance_of?(Array)
			args = value[1]
			value = value[0]
		end

		return nil if value.nil?

		begin
			root_base = nil
			value_bases = []
			mod::TOOL_ROOT.ascend { |v| root_base = v.basename.to_s; break; }
			value.descend { |v| value_bases << v.basename.to_s }

			value_index = value_bases.index(root_base)
			unless value_index.nil?
				value_bases = value_bases[value_index + 1..-1]
				value = Pathname.new(File.join(value_bases))
			end

			value = mod::TOOL_ROOT + value.basename
		rescue
		end

		value = Platform::resolved_tool_path(value)

		if Options::ccache && self != CMake && [:COMPILER_C, :COMPILER_CXX].include?(value_key)
			value = "#{CCACHE_PATH.value!.normalize} #{value}"
		end

		if raw || !args.nil?
			value = value.to_s.gsub('\\', '/')
			value += " #{args}" unless args.nil?
			if raw
				return [name.to_s, value]
			else
				return self.define(name, value)
			end
		end

		return self.define(name, value)
	end

	def define_tools(mod)
		result = self::TOOLS_MAP.map{ |k,v|
			self::define_tool(mod, k, v)
		}
		result.normalize!
		return result
	end

	def define_tools_env(mod)
		result = self::TOOLS_ENV_MAP.map{ |k,v|
			result = self::define_tool(mod, k, v, raw: true)
			KeyValue.new(result[0], result[1]) if !result.nil? && !result.empty?
		}
		result.compact!
		return result
	end
end

module CMake
	extend ToolchainProto

	TOOLS_MAP = {
		:CMAKE_C_COMPILER =>        :COMPILER_C,
		:CMAKE_CXX_COMPILER =>      :COMPILER_CXX,
		:CMAKE_ASM_COMPILER =>      :ASSEMBLER,
		:CMAKE_ASM_MASM_COMPILER => :ASSEMBLER_MASM,
		:CMAKE_LINKER =>            :LINKER,
		:CMAKE_AR =>                :ARCHIVER,
		:CMAKE_NM =>                :NM,
		:CMAKE_RANLIB =>            :RANLIB,
	}.freeze

	TOOLS_ENV_MAP = {
		:CC =>			:COMPILER_C,
		:CXX =>			:COMPILER_CXX,
		:AS =>			:ASSEMBLER,
		:ASM =>			:ASSEMBLER,
		:MASM =>		:ASSEMBLER_MASM,
		:LD =>			:LINKER,
		:AR =>			:ARCHIVER,
		:NM =>			:NM,
		:RANLIB =>	:RANLIB,
	}.freeze

	def self.define(name, value, delimiter: ' ', condition: true)
		return nil unless condition
		return nil if value.nil?
		case value
		when TrueClass, FalseClass
			value = value ? "ON" : "OFF"
		when Array, LazyArray, Set
			value = value.escape_join(delimiter)
		end
		return "-D#{name}=#{value}"
	end
end

module AutoConf
	TOOLS_MAP = {
		:CC =>			:COMPILER_C,
		:CXX =>			:COMPILER_CXX,
		:AS =>			:ASSEMBLER,
		:ASM =>			:ASSEMBLER,
		:MASM =>		:ASSEMBLER_MASM,
		:LD =>			:LINKER,
		:AR =>			:ARCHIVER,
		:NM =>			:NM,
		:RANLIB =>	:RANLIB,
	}.freeze

	TOOLS_ENV_MAP = TOOLS_MAP

	extend ToolchainProto

	def self.define(name, value, delimiter: ' ', condition: true)
		return nil unless condition
		return nil if value.nil?
		if value.is_a?(TrueClass) || value.is_a?(FalseClass)
			value = value ? "on" : "off"
		end
		if value.is_a?(Array) || value.is_a?(LazyArray) || value.is_a?(Set)
			value = value.join(delimiter)
		end
		return "#{name}=#{value}"
	end
end

module LinkTimeOptimization
	class LTOType
		def initialize(value)
			raise "Invalid LTOType value '#{value}'" unless value == false || value.is_a?(String)

			(@value = value).freeze
			self.freeze
		end

		def ==(other) = @value == other.value
		def !=(other) = @value != other.value

		def to_arg = @value == false ? '-fno-lto' : "-flto=#{@value}"
		alias_method :to_s, :to_arg

		def name = @value

		def casename = @value.is_bool? ? @value : "#{@value[0].upcase}#{@value[1..-1]}"
	end

	NONE = LTOType.new(false)
	THIN = LTOType.new('thin')
	FULL = LTOType.new('full')
end

def get_add_env_flags(env_var, *tokens)
	env = ENV[env_var]
	escaped = tokens.map!(&:escape).join(' ')
	return escaped if env.nil?
	return "#{env} #{escaped}"
end

module ToolchainOptions
	module LLVM_Binaries
		def self.gcc_flags? = true
		def self.msvc_flags? = false

		COMPILER_C = where? 'clang'
		COMPILER_CXX = where? 'clang++'
		LINKER = where? 'lld'
		ASSEMBLER = where? 'clang' #'llvm-as'
		ASSEMBLER_MASM = where? 'llvm-as'
		ARCHIVER = where? 'llvm-ar'
		RANLIB = where? 'llvm-ranlib'
		NM = where? 'llvm-nm'
		OBJCOPY = where? 'llvm-objcopy'
		OBJDUMP = where? 'llvm-objdump'
		#LIB = 'llvm-lib'
		RC = where? 'llvm-rc'
		READOBJ = where? 'llvm-readobj'
		STRIP = where? 'llvm-strip'
	end

	module LLVM_CL_Binaries
		def self.gcc_flags? = true
		def self.msvc_flags? = true

		COMPILER_C = 'clang-cl'
		COMPILER_CXX = 'clang-cl'
		LINKER = 'lld-link'
		ASSEMBLER = 'clang-cl'
		ASSEMBLER_MASM = 'ml64' #'llvm-ml' #'llvm-ml' #'clang-cl'
		#ASSEMBLER = 'llvm-ml' #ml64
		#ASSEMBLER_MASM = 'llvm-ml' #ml64
	end

	module Common
		def self.xcc1(*arg)		= arg.map { |a| ["-Xclang", a.to_s] }.flatten!
		def self.xclang(*arg)	= arg.map { |a| "-clang:#{a}" }.flatten!

		def self.conditional(condition, value: nil)
			if condition
				if block_given?
					return yield value
				else
					return value || []
				end
			else
				return []
			end
		end

		def self.cmake_flags(host:)
			return [
				"-G", CMAKE_GENERATOR,
				CMake::define('CMAKE_BUILD_TYPE', Options::configuration),
				CMake::define('CMAKE_LIBRARY_PATH', Directories::Intermediate::get(host)::LIBS),
				CMake::define('CMAKE_INCLUDE_PATH', Directories::Intermediate::get(host)::INCLUDES),
				CMake::define('CMAKE_PREFIX_PATH', Directories::Intermediate::get(host)::PREFIX.uniq, delimiter: ';'),
				CMake::define('CMAKE_POSITION_INDEPENDENT_CODE', true),
				CMake::define('CMAKE_REQUIRED_FLAGS', "-Wno-error=unused-command-line-argument"),
			].normalize!
		end

		def self.autoconf_flags(host:)
			return [
				AutoConf::define('CFLAGS', get_add_env_flags('CFLAGS', "-w", "-I#{Directories::Intermediate::get(host)::INCLUDES}")),
				AutoConf::define('CXXFLAGS', get_add_env_flags('CXXFLAGS', "-w", "-I#{Directories::Intermediate::get(host)::INCLUDES}")),
				AutoConf::define('LDFLAGS', get_add_env_flags('LDFLAGS', "-L#{Directories::Intermediate::get(host)::LIBS}")),
			].normalize!
		end

		def self.environment_variables(host:)
			return []
		end

		def self.cflags(host:) = [
			"-O2",
			"-g0",
			"-fcolor-diagnostics",
			"-Wno-user-defined-literals",
			"-Wno-unused-command-line-argument",
			*xcc1("-fno-pch-timestamp"),
		].normalize!

		def self.cxxflags(host:) = []
		def self.ldflags(host:) = [
#			"-Wl,--gc-sections",
#			"-Wl,--icf=all",
#			"-Wl,--hash-style=both",
#			"-Wl,--discard-all",
#			"-Wl,--whole-archive",
		].normalize!
		def self.asflags(host:) = []
	end

	module Host
		def self.lto? = LinkTimeOptimization::THIN

		CMAKE_FLAGS = LazyArray.new{[
			*parent::Common::cmake_flags(host: true),
			Common::conditional(Platform::windows?) { CMake::define('CMAKE_ASM_MASM_FLAGS', ["/nologo", "/quiet", "/Gy"]) },
		].normalize!}

		AUTOCONF_FLAGS = LazyArray.new{[
			*parent::Common::autoconf_flags(host: true),
		].normalize!}

		ENVIRONMENT_VARIABLES = LazyArray.new{[
			*parent::Common::environment_variables(host: true),
		].normalize!}

		CFLAGS = LazyArray.new{[
			*parent::Common::cflags(host: true),
			lto?
		].normalize!}

		CXXFLAGS = LazyArray.new{[
			*parent::Common::cxxflags(host: true),
		].normalize!}

		LDFLAGS = LazyArray.new{[
			*parent::Common::ldflags(host: true),
		].normalize!}

		ASFLAGS = LazyArray.new{[
			*parent::Common::asflags(host: true),
		].normalize!}

		module Library
			include parent::parent::LLVM_Binaries

			CFLAGS = LazyArray.new{[
				*parent::CFLAGS,
				"-include", COMMON_INCLUDE,
				"-DLIBXML_STATIC=1",
			].normalize!}
			CXXFLAGS = []
			LDFLAGS = []
			ASFLAGS = []
			CMAKE_FLAGS = LazyArray.new{[
				*parent::CMAKE_FLAGS,
				*CMake::define_tools(self),
				CMake::define("CMAKE_C_FLAGS_#{Options::configuration.upcase}", "-w"),
				#Common::conditional(Platform::windows?) { CMake::define('CMAKE_RC_FLAGS', "/nologo") },
			].normalize!}

			AUTOCONF_FLAGS = LazyArray.new{[
				*parent::AUTOCONF_FLAGS,
				*AutoConf::define_tools(self),
			].normalize!}

			ENVIRONMENT_VARIABLES = LazyArray.new{[
				*parent::ENVIRONMENT_VARIABLES,
				*AutoConf::define_tools_env(self),
			].normalize!}
		end

		module Executable
			if Platform::windows?
				include parent::parent::LLVM_CL_Binaries
			else
				include parent::parent::LLVM_Binaries
			end

			def self.xlink(*arg)= Common::conditional(Platform::windows?) { arg.map { |a| ["/LINK", arg.to_s] }.flatten! }

			CFLAGS = LazyArray.new{[
				#"/FI", COMMON_INCLUDE,
				#"/GS-", # disable buffer security check
				##"/Gs-", # disable stack probe
				##"/GT", # fiber-safe local storage
				#"/Gw",	# global data COMDAT sections
				#"/Gy",	#	function-level linking
				#"/Oi",	# intrinsic replacement
				#"/volatile:iso", # ISO volatile instead of MS
				##"/Ob3",	# aggressive inlining

				#"-fuse-ld=lld",
				#parent::parent::lto?,
				*Common::xclang("-fcolor-diagnostics"),
				*Common::xclang("-Wno-user-defined-literals",),
				*Common::xcc1("-fno-pch-timestamp"),
				#*xclang(parent::parent::lto?),
				"-DLIBXML_STATIC=1",
				"-DLZMA_API_IMPORT",
				"-DZSTD_DLL_IMPORT=0",
				"-DZSTD_STATIC_LINKING_ONLY=1",
				"-DZLIB_COMPAT=1",
			].normalize!}
			CXXFLAGS = []
			LDFLAGS = LazyArray.new{[
#				"/LARGEADDRESSAWARE",
#				"/OPT:REF",
#				"/OPT:ICF",
#				"/WHOLEARCHIVE",
			].normalize!}
			ASFLAGS = []
			CMAKE_FLAGS = LazyArray.new{[
				*parent::CMAKE_FLAGS,
				*CMake::define_tools(self),
			].normalize!}

			AUTOCONF_FLAGS = LazyArray.new{[
				*parent::AUTOCONF_FLAGS,
				*AutoConf::define_tools(self),
			].normalize!}

			ENVIRONMENT_VARIABLES = LazyArray.new{[
				*parent::ENVIRONMENT_VARIABLES,
				*AutoConf::define_tools_env(self),
			].normalize!}
		end
	end

	module Target
		def self.lto? = LinkTimeOptimization::FULL

		CMAKE_FLAGS = LazyArray.new{[
			*parent::Common::cmake_flags(host: false),
			CMake::define("CMAKE_C_COMPILER_WORKS", true),
			CMake::define("CMAKE_CXX_COMPILER_WORKS", true),
			#CMake::define("TARGET_SUPPORTS_SHARED_LIBS", true),
		].normalize!}

		AUTOCONF_FLAGS = LazyArray.new{[
			*parent::Common::autoconf_flags(host: false),
		].normalize!}

		ENVIRONMENT_VARIABLES = LazyArray.new{[
			*parent::Common::environment_variables(host: false),
		].normalize!}

		CFLAGS = LazyArray.new{[
			*parent::Common::cflags(host: false),
			lto?,
			"-march=mips32r6",
			#"-I#{Directories::Intermediate::get(false)::INCLUDES}",
			*[Directories::Intermediate::get(false)::LIBS].flatten.map { |path| "-L#{path}" }
		].normalize!}

		CXXFLAGS = LazyArray.new{[
			*parent::Common::cxxflags(host: false),
		].normalize!}

		LDFLAGS = LazyArray.new{[
			*parent::Common::ldflags(host: false)
		].normalize!}

		ASFLAGS = LazyArray.new{[
			*parent::Common::asflags(host: false),
		].normalize!}

		module Library
			include parent::parent::LLVM_Binaries

			TOOL_ROOT = Directories::Intermediate::Host::ROOT + 'llvm-exe.stage1' + 'bin'

			CFLAGS = LazyArray.new{[
				*parent::CFLAGS
			].normalize!}
			CXXFLAGS = []
			LDFLAGS = []
			ASFLAGS = []
			CMAKE_FLAGS = LazyArray.new{[
				*parent::CMAKE_FLAGS,
				*CMake::define_tools(self),

				CMake::define("CMAKE_FIND_ROOT_PATH", Directories::Intermediate::get(false)::PREFIX.uniq.join(';')),
				CMake::define("CMAKE_FIND_ROOT_PATH_MODE_PROGRAM", 'BOTH'),
				CMake::define("CMAKE_FIND_ROOT_PATH_MODE_LIBRARY", 'ONLY'),
				CMake::define("CMAKE_FIND_ROOT_PATH_MODE_INCLUDE", 'ONLY'),
				CMake::define("CMAKE_FIND_ROOT_PATH_MODE_PACKAGE", 'ONLY'),

				#CMake::define("CMAKE_TRY_COMPILE_TARGET_TYPE", 'STATIC_LIBRARY'),
			].normalize!}

			AUTOCONF_FLAGS = LazyArray.new{[
				*parent::AUTOCONF_FLAGS,
				*AutoConf::define_tools(self),
			].normalize!}

			ENVIRONMENT_VARIABLES = LazyArray.new{[
				*parent::ENVIRONMENT_VARIABLES,
				*AutoConf::define_tools_env(self),
			].normalize!}
		end

		module LibraryStage2
			include parent::parent::LLVM_Binaries

			TOOL_ROOT = Directories::Intermediate::Host::ROOT + 'llvm.stage1' + 'bin'

			CFLAGS = LazyArray.new{[
				*parent::CFLAGS
			].normalize!}
			CXXFLAGS = []
			LDFLAGS = []
			ASFLAGS = []
			CMAKE_FLAGS = LazyArray.new{[
				*parent::CMAKE_FLAGS,
				*CMake::define_tools(self),

				CMake::define("CMAKE_FIND_ROOT_PATH", Directories::Intermediate::get(false)::PREFIX.uniq.join(';')),
				CMake::define("CMAKE_FIND_ROOT_PATH_MODE_PROGRAM", 'BOTH'),
				CMake::define("CMAKE_FIND_ROOT_PATH_MODE_LIBRARY", 'ONLY'),
				CMake::define("CMAKE_FIND_ROOT_PATH_MODE_INCLUDE", 'ONLY'),
				CMake::define("CMAKE_FIND_ROOT_PATH_MODE_PACKAGE", 'ONLY'),

				#CMake::define("CMAKE_TRY_COMPILE_TARGET_TYPE", 'STATIC_LIBRARY'),
			].normalize!}

			AUTOCONF_FLAGS = LazyArray.new{[
				*parent::AUTOCONF_FLAGS,
				*AutoConf::define_tools(self),
			].normalize!}

			ENVIRONMENT_VARIABLES = LazyArray.new{[
				*parent::ENVIRONMENT_VARIABLES,
				*AutoConf::define_tools_env(self),
			].normalize!}
		end

		module LibraryBuiltin
			include parent::parent::LLVM_Binaries

			TOOL_ROOT = Directories::Intermediate::Host::ROOT + 'llvm-exe.stage1' + 'bin'

			CFLAGS = LazyArray.new{[
				*parent::CFLAGS,
	#			"-nodefaultlibs"
			].normalize!}
			CXXFLAGS = []
			LDFLAGS = []
			ASFLAGS = []
			CMAKE_FLAGS = LazyArray.new{[
				*parent::CMAKE_FLAGS,
				*CMake::define_tools(self),
				CMake::define("CMAKE_C_COMPILER_WORKS", true),
				CMake::define("CMAKE_CXX_COMPILER_WORKS", true),
				CMake::define("LLVM_BUILD_EXTERNAL_COMPILER_RT", true),

				CMake::define("COMPILER_RT_BUILD_LIBFUZZER", false),
				CMake::define("COMPILER_RT_BUILD_MEMPROF", false),
				CMake::define("COMPILER_RT_BUILD_PROFILE", false),
				CMake::define("COMPILER_RT_BUILD_SANITIZERS", false),
				CMake::define("COMPILER_RT_BUILD_XRAY", false),

				CMake::define("CMAKE_FIND_ROOT_PATH_MODE_PROGRAM", 'BOTH'),
				CMake::define("CMAKE_FIND_ROOT_PATH_MODE_LIBRARY", 'ONLY'),
				CMake::define("CMAKE_FIND_ROOT_PATH_MODE_INCLUDE", 'ONLY'),
				CMake::define("CMAKE_FIND_ROOT_PATH_MODE_PACKAGE", 'ONLY'),

				CMake::define("CMAKE_C_COMPILER_TARGET", TRIPLE),
				CMake::define("CMAKE_CXX_COMPILER_TARGET", TRIPLE),

				CMake::define("LIBCXX_ENABLE_TIME_ZONE_DATABASE", false),

				#CMake::define("LLVM_DIR", Directories::Intermediate::get(true)::ROOT + 'llvm-exe.stage1' + 'lib' + 'cmake' + 'llvm'),
				#CMake::define("LLVM_CMAKE_DIR", Directories::Intermediate::get(true)::ROOT + 'llvm-exe.stage1' + 'lib' + 'cmake' + 'llvm'),
				CMake::define("LLVM_DIR", Directories::ROOT + 'llvm-project' + 'llvm' + 'cmake' + 'modules'),
				#CMake::define("CLANG_DIR", Directories::ROOT + 'llvm-project' + 'clang' + 'cmake' + 'modules'),
				CMake::define("CLANG_DIR", Directories::Intermediate::get(true)::ROOT + 'llvm-exe.stage1' + 'bin'),

				CMake::define("LLVM_CMAKE_DIR", Directories::ROOT + 'llvm-project' + 'llvm'),
				#CMake::define("LLVM_CONFIG_PATH", Directories::Intermediate::get(true)::ROOT + 'llvm-exe.stage1' + 'tools' + 'llvm-config'),

				CMake::define("CMAKE_MAKE_PROGRAM", where?('ninja')),

				#CMake::define("CMAKE_TRY_COMPILE_TARGET_TYPE", 'STATIC_LIBRARY'),
			].normalize!}

			AUTOCONF_FLAGS = LazyArray.new{[
				*parent::AUTOCONF_FLAGS,
				*AutoConf::define_tools(self),
			].normalize!}

			ENVIRONMENT_VARIABLES = LazyArray.new{[
				*parent::ENVIRONMENT_VARIABLES,
				*AutoConf::define_tools_env(self),
			].normalize!}
		end
	end
end

module Environment
	class <<self
		attr_accessor :current
	end

	def self.flag_mapping(old_flags, new_flags, alt) = "#{old_flags} #{new_flags.join(' ')}".strip

	def self.conditional_path(mod, sym, alt, unix:)
		value = mod.evaluate(sym)
		value_ext = []

		if value.is_a?(Array)
			value_ext = value[1..-1]
			value = value[0]
		end

		value = mod::TOOL_ROOT + value if mod::const_defined?(:TOOL_ROOT)

		return nil unless alt

		normalized_path = resolve_tool_path(value, unix: unix)

		normalized_path += " #{value_ext.join(' ')}" unless value_ext.empty?

		return normalized_path
	end

	def self.tool_map(sym) = lambda { |orig, mod, alt, unix| conditional_path(mod, sym, alt, unix: unix) rescue nil }

	def self.flag_map(sym) = lambda { |orig, mod, alt, unix| flag_mapping(orig, mod.evaluate(sym), alt) rescue nil }

	ENV_MAPPING_FLAGS = {
		:CFLAGS   => flag_map(:CFLAGS),
		:CXXFLAGS => flag_map(:CXXFLAGS),
		:LDFLAGS  => flag_map(:LDFLAGS),
		:ASFLAGS  => flag_map(:ASFLAGS),
		:RCFLAGS  => flag_map(:RCFLAGS),
		:CCACHE_CONFIGPATH => lambda { |orig, mod, alt, unix| File.combine(File.dirname($0), "ccache.conf") }
	}

	ENV_MAPPING_BINARIES = {
		:CC       => tool_map(:COMPILER_C),
		:CXX      => tool_map(:COMPILER_CXX),
		:LD       => tool_map(:LINKER),
		:AS       => tool_map(:ASSEMBLER),
		:ASM_MASM => tool_map(:ASSEMBLER_MASM),
		:AR       => tool_map(:ARCHIVER),
		:RANLIB   => tool_map(:RANLIB),
		:NM       => tool_map(:NM),
		:OBJCOPY  => tool_map(:OBJCOPY),
		:OBJDUMP  => tool_map(:OBJDUMP),
		#:LIB   	=> tool_map(:LIB),
		:RC       => tool_map(:RC),
		:READOBJ  => tool_map(:READOBJ),
		:STRIP    => tool_map(:STRIP),
	}

	ENV_MAPPING = ENV_MAPPING_FLAGS.merge(ENV_MAPPING_BINARIES)

	def self.configure(item, mod, alt, unix_path: false)
		original = Hash.new

		env_mapping = ENV_MAPPING.dup

		if (mod.instance_of?(Module))
			mod::ENVIRONMENT_VARIABLES.each { |kvp|
				env_mapping[kvp.key] = kvp.value
			}
		end

		max_key = env_mapping.keys.max_by{ |k| k.length }.length

		updated_flags = Hash.new

		orig_path = ENV['PATH']
		# remove msys2 from paths
		if item.no_msys && Platform::windows_native?
			path_env = ENV['PATH']
			unless path_env.nil?
				path_env = path_env.split(';')
				path_env.reject! { |p| p.downcase.include?('msys') }
				ENV['PATH'] = path_env.join(';')
			end
		end

		env_mapping.each { |key_s, func|
			next if func.nil?
			key = key_s.to_s
			original[key] = orig = ENV[key]
			orig = nil unless Options::with_environment
			if func.instance_of?(String)
				new_value = func
			elsif func.instance_of?(Array)
				new_value = func.join(' ')
			else
				new_value = func[orig, mod, alt, unix_path] rescue nil
			end
			next if new_value.nil?

			if new_value.instance_of?(Array)
				new_value = new_value.join(' ')
			end

			if Options::ccache && ['CC', 'CXX'].include?(key) && !new_value.start_with?(CCACHE_PATH.value!.normalize.to_s)
				new_value = "#{CCACHE_PATH.value!.normalize} #{new_value}"
			end
			updated_flags[key] = ENV[key] = new_value.to_s
		}

		ENV_MAPPING_FLAGS.each { |key_s, func|
			next if func.nil?
			key = key_s.to_s
			item_value = item.extra[key_s]
			next if item_value.nil?
			updated_value = updated_flags[key]
			orig = nil
			if updated_value.nil?
				original[key] = orig = ENV[key]
				orig = nil unless Options::with_environment
			else
				orig = updated_value
			end
			new_value = flag_mapping(orig, item_value, alt) rescue nil

			next if new_value.nil?
			updated_flags[key] = ENV[key] = new_value.to_s
		}

		updated_flags.each { |key, func|
			puts "'#{key.light_yellow}'#{' ' * (max_key - key.length)} = '#{ENV[key].light_yellow}'"
		}

		self.current = mod

		begin
		yield
		ensure
		self.current = nil

		ENV_MAPPING.each { |key_s, func|
			next if func.nil?
			key = key_s.to_s
			ENV[key] = original[key]
		}
		ENV['PATH'] = orig_path
		end
	end
end

recursive_require(File.combine(__dir__, "toolchains"))
