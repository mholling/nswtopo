module NSWTopo
  module RasterRender
    def render(**, &block)
      defs = REXML::Element.new("defs").tap(&block)
      defs.add_attributes "id" => "#{@name}.defs"

      Dir.mktmppath do |tmp|
        tmp.join("temp.tif").binwrite @map.read(filename)
        OS.gdal_translate "-of", "PNG", "-co", "ZLEVEL=9", "temp.tif", "/vsistdout/", chdir: tmp
      end.tap do |png|
        (width, height), resolution = size_resolution
        transform = "scale(#{resolution / @map.metres_per_mm})"
        href = "data:image/png;base64,#{Base64.encode64 png}"
        defs.add_element "image", "id" => "#{@name}.content", "transform" => transform, "width" => width, "height" => height, "image-rendering" => "optimizeQuality", "href" => href
      end

      REXML::Element.new("use").tap do |use|
        use.add_attributes "id" => @name, "href" => "##{@name}.content"
        use.add_attributes params.slice("opacity")
      end.tap(&block)
    end
  end
end
