@[Link("d4binding")]
lib LibD4
  # Basic types
  type D4File = Void*
  type D4TaskPart = Void*

  # Enums
  enum DictType : Int32
    SimpleRange = 0
    ValueMap    = 1
  end

  enum TaskMode : Int32
    Read  = 0
    Write = 1
  end

  enum IndexKind : Int32
    Sum = 0
  end

  # Structs
  struct SimpleRangeDict
    low : Int32
    high : Int32
  end

  struct ValueMapDict
    size : LibC::SizeT
    values : Int32*
  end

  union DictData
    simple_range : SimpleRangeDict
    value_map : ValueMapDict
  end

  struct FileMetadata
    chrom_count : LibC::SizeT
    chrom_name : LibC::Char**
    chrom_size : UInt32*
    dict_type : DictType
    denominator : Float64
    dict_data : DictData
  end

  struct Interval
    left : UInt32
    right : UInt32
    value : Int32
  end

  union IndexResult
    sum : Float64
  end

  struct TaskPartResult
    task_context : Void*
    status : Int32
  end

  struct TaskDesc
    mode : TaskMode
    part_size_limit : UInt32
    num_cpus : UInt32
    part_context_create_cb : (D4TaskPart*, Void*) -> Void*
    part_process_cb : (D4TaskPart*, Void*, Void*) -> Int32
    part_finalize_cb : (TaskPartResult*, LibC::SizeT, Void*) -> Int32
    extra_data : Void*
  end

  # Basic file operations
  fun d4_open = d4_open(path : LibC::Char*, mode : LibC::Char*) : D4File
  fun d4_close = d4_close(handle : D4File) : Int32

  # Metadata operations
  fun d4_file_load_metadata = d4_file_load_metadata(handle : D4File, buf : FileMetadata*) : Int32
  fun d4_file_update_metadata = d4_file_update_metadata(handle : D4File, metadata : FileMetadata*) : Int32

  # Streaming API
  fun d4_file_read_values = d4_file_read_values(handle : D4File, buf : Int32*, count : LibC::SizeT) : LibC::SSizeT
  fun d4_file_read_intervals = d4_file_read_intervals(handle : D4File, buf : Interval*, count : LibC::SizeT) : LibC::SSizeT
  fun d4_file_write_values = d4_file_write_values(handle : D4File, buf : Int32*, count : LibC::SizeT) : LibC::SSizeT
  fun d4_file_write_intervals = d4_file_write_intervals(handle : D4File, buf : Interval*, count : LibC::SizeT) : LibC::SSizeT
  fun d4_file_tell = d4_file_tell(handle : D4File, name_buf : LibC::Char*, buf_size : LibC::SizeT, pos_buf : UInt32*) : Int32
  fun d4_file_seek = d4_file_seek(handle : D4File, chrom : LibC::Char*, pos : UInt32) : Int32

  # Index operations
  fun d4_index_build_sfi = d4_index_build_sfi(path : LibC::Char*) : Int32
  fun d4_index_check = d4_index_check(handle : D4File, kind : IndexKind) : Int32
  fun d4_index_query = d4_index_query(handle : D4File, kind : IndexKind, chrom : LibC::Char*, start : UInt32, end_pos : UInt32, buf : IndexResult*) : Int32

  # Task/parallel operations
  fun d4_file_run_task = d4_file_run_task(handle : D4File, task : TaskDesc*) : Int32
  fun d4_task_read_values = d4_task_read_values(task : D4TaskPart*, offset : UInt32, buffer : Int32*, count : LibC::SizeT) : LibC::SSizeT
  fun d4_task_write_values = d4_task_write_values(task : D4TaskPart*, offset : UInt32, data : Int32*, count : LibC::SizeT) : LibC::SSizeT
  fun d4_task_read_intervals = d4_task_read_intervals(task : D4TaskPart*, data : Interval*, count : LibC::SizeT) : LibC::SSizeT
  fun d4_task_chrom = d4_task_chrom(task : D4TaskPart*, name_buf : LibC::Char*, name_buf_size : LibC::SizeT) : Int32
  fun d4_task_range = d4_task_range(task : D4TaskPart*, left_buf : UInt32*, right_buf : UInt32*) : Int32

  # Error handling
  fun d4_error_clear = d4_error_clear : Void
  fun d4_error_message = d4_error_message(buf : LibC::Char*, size : LibC::SizeT) : LibC::Char*
  fun d4_error_num = d4_error_num : Int32
end
