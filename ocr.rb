require 'mini_magick'
require 'geometry'
require 'csv'
require 'open3'
require 'json'

include Geometry
input_filename = ARGV[0]

orientation_output = `tesseract #{input_filename} stdout -psm 0 2>&1`

if orientation_output[/too few characters/]
  exit
else
  #puts orientation_output
  orientation = orientation_output[/Orientation in degrees: (\d+)/].to_s[/\d+/]
end

if orientation.to_i != 0
  `sips -r #{orientation} #{input_filename}`
end

MiniMagick::Tool::Convert.new do |convert|
  convert << input_filename
  convert.merge! ['-deskew', '10%', '-canny', "0x1+10%+40%"]
  convert.merge! %w{-background black -fill white -stroke white -strokewidth 7}
  convert.merge! ["-hough-lines", "40x40+0"]
  convert.merge! ["-negate"]
  convert.merge! ["-write", "mask-#{input_filename}", "rectangle_lines.mvg"]
end

input = IO.read('rectangle_lines.mvg')

# Make masked version of the file
# We knock out the table lines using the stroke lines
# produced in the Hough transform
MiniMagick::Tool::Convert.new do |convert|
  convert << input_filename
  convert.merge! ['-deskew', '10%']
  convert.merge! ['-mask', "mask-#{input_filename}"]
  convert.merge! ['-morphology', 'Dilate:15', 'Diamond', '+mask']
  convert.merge! ["masked-#{input_filename}"]
end

# Do a general OCR with hOCR and check for tables
stdout, stderr, exit_status = Open3.capture3("tesseract masked-#{input_filename} stdout -psm 6  -c textord_tablefind_recognize_tables=1 -c gapmap_debug=1 -c gapmap_use_ends=1 -c tessedit_create_hocr=1")

#if not stderr[/Table found/].nil?
  @table_detected = true
#end

@raw_hocr_output = stdout

# If tables split out the cells
if @table_detected
  # Collect the horizontal lines
  # Collect the vertical lines
  #
  # Select all the horizontal lines that are intersected by every vertical ???
  #
  # trim space between edges and main grid
  #
  # Get segment for each box in turn
  #
  # horizA,vert1 horizA,vert2 horizB,vert1 horizB,vert2
  #
  # split that box
  # ocr that box

  viewbox = input.each_line.detect {|x| x[/^viewbox/]}
  viewbox_numbers = viewbox.match(/viewbox ([\d\.]+) ([\d\.]+) ([\d\.]+) ([\d\.]+)/).to_a[1..-1]
  doc_x,doc_y,doc_x1,doc_y1 = viewbox_numbers.map(&:to_f)
  @doc_box = BoundingBox.new(Point.new(doc_x,doc_y), Point.new(doc_x1,doc_y1))
  @horizontal_line = Line.new(Point.new(0,0), Point.new(doc_x1,0))
  @vertical_line = Line.new(Point.new(0,0), Point.new(0,doc_y1))


  lines_raw = input.each_line.select {|x| x[/^line/] }

  lines = lines_raw.map {|l|
    numbers = l.match(/line ([\d\.\-]+),([\d\.\-]+) ([\d\.\-]+),([\d\.\-]+)  \# ([\d\.\-]+)/).to_a[1..-2]
    x,y,x1,y1 = numbers.map(&:to_f)
    Line.new(Point.new(x,y), Point.new(x1,y1))
  }

  horizontal_lines = lines.select {|l|
    Math::atan(l.slope).abs.round(1) == 0.0
  }

  vertical_lines = lines.select {|l|
    l.vertical?
    # l.slope == (1.0/0) # || Math::atan(l.slope).abs.round(1) == 1.5
  }

  file_path = Pathname.new(input_filename)
  @file_prefix = Pathname.new(input_filename).split.last.sub(file_path.extname, '')
  @output_csv = []
  @cell_crops = {}
  horizontal_lines.select {|h|
    vertical_lines.all? {|v| v.intersect_x(h) }
  }.each_cons(2).with_index {|(a,b), line_no|
    height = b.point1.y - a.point1.y
    offset_y = a.point1.y

    next if height.to_f == 0.0

    vertical_lines.each_cons(2).with_index {|(j,k), col_no|
      width = k.point1.x - j.point1.x
      offset_x = j.point1.x

      @output_filename = "#{@file_prefix}-line-#{line_no}_col-#{col_no}.pbm"

      @cell_crops[@output_filename] = ['-crop', "#{width}x#{height}+#{offset_x}+#{offset_y}"]
    }
  }

  MiniMagick::Tool::Convert.new do |convert|
    convert << "masked-#{input_filename}"
    @cell_crops.each do |output_filename, crop_command|
      convert.merge! ['(', '+clone', crop_command, '-write', output_filename, '+delete', ')'].flatten
    end
    # output to stdout here as we don't care about the result
    # (only the interim crops)
    convert << 'gif:-'
  end

  @cell_crops.each do |output_filename, crop_command|
    col_no = output_filename.match(/col-(\d+)/).to_a.last.to_i
    line_no = output_filename.match(/line-(\d+)/).to_a.last.to_i

    text = `tesseract #{output_filename} stdout -psm 6 -c tessedit_char_blacklist=\\\| 2>/dev/null`
    text_gocr = `gocr #{output_filename}`
    text_ocrad = `ocrad -F utf8 #{output_filename}`

    @cell_crops[output_filename] = {command: crop_command}
    @cell_crops[output_filename]["line_#{line_no}".to_sym] ||= []
    @cell_crops[output_filename]["line_#{line_no}".to_sym] << {"cell_#{col_no}".to_sym => {
      text_tesseract: text,
      text_gocr: text_gocr,
      text_ocrad: text_ocrad,
      crop_command: crop_command
    }}

    @output_csv[line_no] ||= []
    @output_csv[line_no][col_no] = text
  end

  @output_csv = CSV::Table.new(@output_csv.map {|r| CSV::Row.new([], r) }).to_csv

  # no_cols = CSV.parse(@output_csv.first).length
  # blank_cols = []
  # (0..no_cols).to_a.each do |i|
  #   @output_csv.each {|row|
  #     col_vals = CSV.parse(row)[i]
  #     unless col_vals.to_s[/A-Za-z0-9/]
  #       blank_cols << i
  #     end
  #   }
  # end

  # require 'pry'; binding.pry
  # blank_cols.sort.reverse.each do |col|
  #   @output_csv.map! {|x| arr = CSV.parse(x); arr[col] = nil; arr.compact.join }
  # end

  File.open("#{@file_prefix}.json", 'w') {|f| f.write @cell_crops.to_json }
  File.open("#{@file_prefix}.csv", 'w') {|f| f.write @output_csv }
  File.open("#{@file_prefix}.html", 'w') {|f| f.write @raw_hocr_output }
end
