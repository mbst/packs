require 'sinatra'
require 'sinatra/reloader' if development?
require 'RMagick'
require 'digest/md5'

require 'net/http'
require 'uri'
require 'securerandom'
require 'tmpdir' 

include Magick

# HTTP requester with redirection following
def http_fetch(uri_str, limit = 3)
  raise ArgumentError, 'HTTP redirect too deep' if limit <= 0

  uri = URI.parse(uri_str)
  request = Net::HTTP::Get.new(uri.path, {'User-Agent' => 'MetaBroadcast image resizer'})
  response = Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') { |http| http.request(request) }

  case response
  when Net::HTTPRedirection then http_fetch(response['location'], limit - 1)
  else
    response
  end
end

class PackImg < Sinatra::Base

  get '/' do
    
    allowed = %w(source resize perspective profile)
    params.keep_if { |k,v| allowed.include? k.to_s }

    return "Invalid parameters. Required: \"source\"; allowed: #{allowed}" unless params[:source]
  
    etag Digest::MD5.hexdigest( params.values.sort.join(',') )


    begin
      response = http_fetch(params[:source])

      # If we got an error from the source, pass on the http error code and body
      if response.code.to_i >= 300
        status response.code
        return response.body
      end

      # Attempt load the body as an image
      img = Image.from_blob(response.body)[0]

    rescue ArgumentError
      # redirect limit hit
      status 500
      return "Too many redirects fetching source image"
    rescue Magick::ImageMagickError
      # image load failed
      status 500
      return "Error processing source image"
    end
    
    ops = []
    ops << ->(image) { image }

    ops << ->(image) { image.resize_to_fit(*params[:resize].split('x'))} if params[:resize]

    ops << ->(image) { params[:flip] == 'vertical' ? image.flip : image.flop } if params[:flip]

    if params[:perspective]
      img.format = "png"
      img.virtual_pixel_method = Magick::TransparentVirtualPixelMethod
      ops << ->(image) { image.distort(Magick::PerspectiveDistortion, params[:perspective].split(',').collect{|x| x.to_f}) }
    end
    
    if params[:profile] == "monocrop"
      tempName = Dir.tmpdir() + "/" + SecureRandom.hex
      img.write(tempName)
      # Not ideal, but RMagick doesn't seem to expose the right API to do all of the below
      if !system("convert #{tempName} -density 150 -threshold 60% -trim \
          -transparent black -fill \"#EBEBEB\" -enhance -opaque white \
          -colorspace gray #{tempName}-monocropped.png") ||
          !system("convert #{tempName}-monocropped.png -trim #{tempName}-monocropped.png")
        status 500
        return "Server Error"
      end
      img = Image.read("#{tempName}-monocropped.png")[0]
      img.format = "png"
      FileUtils.rm("#{tempName}-monocropped.png")
      FileUtils.rm("#{tempName}")
    end

    if params[:profile] == "sixteen-nine-blur"
      minHeight = 576
      tempName = Dir.tmpdir() + "/" + SecureRandom.hex
      img.write(tempName)
      height = `convert #{tempName} -format "%h" info:`.to_i
      if height < minHeight
        height = minHeight
      end
      width = (height * 16) / 9
      if !system("convert #{tempName} \
        \\( -clone 0 -resize #{width}x#{height}! -blur 0x20 -set option:modulate:colorspace hsb -modulate 100,75 \\) \
        \\( -clone 0 -resize 0x#{height}^ -gravity center \\) -delete 0 -composite #{tempName}-sixteen-nine-blur.png")
        status 500
        return "Server Error"
      end
      img = Image.read("#{tempName}-sixteen-nine-blur.png")[0]
      img.format = "png"
      headers \
        "X-MBST-Image-Size" => `convert #{tempName}-sixteen-nine-blur.png -format "%wx%h" info:`
      FileUtils.rm("#{tempName}-sixteen-nine-blur.png")
      FileUtils.rm("#{tempName}")
    end

    if params[:profile] == "sixteen-nine-blur-fixed-dimensions"
      fixedWidth = 1024
      fixedHeight = 576
      tempName = Dir.tmpdir() + "/" + SecureRandom.hex
      img.write(tempName)
      if !system("convert #{tempName} \
        \\( -clone 0 -resize #{fixedWidth}x#{fixedHeight}! -blur 0x20 -set option:modulate:colorspace hsb -modulate 100,75 \\) \
        \\( -clone 0 -resize x#{fixedHeight} -gravity center \\) -delete 0 -composite #{tempName}-sixteen-nine-blur-fixed-dimensions.png")
        status 500
        return "Server Error"
      end
      img = Image.read("#{tempName}-sixteen-nine-blur-fixed-dimensions.png")[0]
      img.format = "png"
      FileUtils.rm("#{tempName}-sixteen-nine-blur-fixed-dimensions.png")
      FileUtils.rm("#{tempName}")
    end
    
    ops << ->(image) { image.rotate(params[:rotate].to_i) } if params[:rotate]

    res = ops.inject(img) {|o,proc| proc.call(o)}
    
    res.format = params[:format] if params[:format]

    res.quality = params[:quality].to_i if params[:quality]

    content_type res.mime_type

    res.to_blob
  end

  error do
    env['sinatra.error']
  end
end


