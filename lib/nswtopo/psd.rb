module NSWTopo
  module PSD
    def self.build(config, map, ppi, svg_path, composite_png_path, temp_dir, psd_path)
      xml = REXML::Document.new(svg_path.read)
      xml.elements["/svg/rect"].remove
      xml.elements.delete_all("/svg/g[@id]").map do |group|
        id = group.attributes["id"]
        puts "    Generating layer: #{id}"
        layer_svg_path, layer_png_path = %w[svg png].map { |ext| temp_dir + [ map.name, id, ext ].join(?.) }
        xml.elements["/svg"].add group
        layer_svg_path.open("w") { |file| xml.write file }
        group.remove
        Raster.build(config, map, ppi, layer_svg_path, temp_dir, layer_png_path)
        # Dodgy; Make sure there's a coloured pixel or imagemagick won't fill in the G and B channels in the PSD:
        %x[mogrify -label #{id} -fill "#FFFFFEFF" -draw 'color 0,0 point' "#{layer_png_path}"]
        layer_png_path
      end.unshift(composite_png_path).map do |layer_png_path|
        %Q[#{OP} "#{layer_png_path}" -units PixelsPerInch #{CP}]
      end.join(?\s).tap do |sequence|
        %x[convert #{sequence} "#{psd_path}"]
      end
    end
  end
end
