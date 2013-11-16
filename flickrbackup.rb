#!/usr/bin/env ruby
# encoding: utf-8

# https://github.com/jawj/iphoto-flickr

# Copyright (c) George MacKerron 2013, http://mackerron.com
# Released under GPLv3: http://opensource.org/licenses/GPL-3.0

%w{flickraw-cached tempfile fileutils yaml}.each { |lib| require lib }


# own records setup

dataDirName = File.expand_path "~/Library/Application Support/flickrbackup"
FileUtils.mkpath dataDirName

class PersistedIDsHash
  ID_SEP = ' -> '
  def initialize(fileName)
    @hash = {}
    FileUtils.touch fileName
    open(fileName).each_line do |line|
      k, v = line.chomp.split ID_SEP
      store k, v
    end
    open(fileName, 'a') do |file|
      @file = file
      yield self
    end
  end
  def add(k, v)
    store k, v
    record = "#{k}#{ID_SEP}#{v}"
    @file.puts record
    @file.fsync
    record
  end
  def get(k)
    @hash[k]
  end
private
  def store(k, v)
    @hash[k] = v
  end
end

class PersistedIDsHashMany < PersistedIDsHash
  def associated?(k, v)
    @hash[k] && @hash[k][v]
  end
private
  def store(k, v)
    (@hash[k] ||= {})[v] = true
  end
end


# AppleScript setup

AS_SEP = "\u0000"

def applescript(source, *args)
  IO.popen(['osascript', '-', *args], 'w') { |io| io.write(source) }
end

def loadOutputFile(fileName)
  open(fileName, 'rb:utf-16be:utf-8').each_line(AS_SEP).map { |datum| datum.chomp AS_SEP }
end


# Flickr API setup

credentialsFileName = "#{dataDirName}/credentials.yaml"

if File.exist? credentialsFileName
  credentials = YAML.load_file credentialsFileName
  FlickRaw.api_key        = credentials[:api_key] 
  FlickRaw.shared_secret  = credentials[:api_secret]
  flickr.access_token     = credentials[:access_token]
  flickr.access_secret    = credentials[:access_secret]
  login = flickr.test.login
  puts "Authenticated as: #{login.username}"

else
  print "Flickr API key: "
  FlickRaw.api_key = gets.strip
  
  print "Flickr API shared secret: "
  FlickRaw.shared_secret = gets.strip
  
  token = flickr.get_request_token
  auth_url = flickr.get_authorize_url(token['oauth_token'], :perms => 'write')
  print "Authorise access to your Flickr account: press [Return] when ready"
  gets
  `open '#{auth_url}'`

  print "Authorisation code: "
  verify = gets.strip
  flickr.get_access_token(token['oauth_token'], token['oauth_token_secret'], verify)
  login = flickr.test.login
  puts "Authenticated as: #{login.username}"

  credentials = {api_key:       FlickRaw.api_key, 
                 api_secret:    FlickRaw.shared_secret, 
                 access_token:  flickr.access_token,
                 access_secret: flickr.access_secret}

  File.open(credentialsFileName, 'w') { |credentialsFile| YAML.dump(credentials, credentialsFile) }
end

def rateLimit
  startTime = Time.now
  returnValue = yield
  timeTaken = Time.now - startTime
  timeToSleep = 1.01 - timeTaken  # rate limit to just under 3600 reqs/hour
  sleep timeToSleep if timeToSleep > 0
  returnValue
end


# load own backup records

PersistedIDsHash.new("#{dataDirName}/uploaded-photo-ids-map.txt") do |uploadedPhotos|
PersistedIDsHash.new("#{dataDirName}/created-album-ids-map.txt") do |createdAlbums|
PersistedIDsHashMany.new("#{dataDirName}/photos-in-album-ids-map.txt") do |photosInAlbums|


# get all iPhoto IDs and paths, and filter out those already backed up

idsFile   = Tempfile.new 'ids'
pathsFile = Tempfile.new 'paths'
albumsFile = Tempfile.new 'albums'

[idsFile, pathsFile, albumsFile].each { |f| f.close }

#TODO Path to Photo library (using apple script?)

IO.popen(['python', 'writeidsandpathes.py','--albums-file', albumsFile.path, '--ids-file', idsFile.path, '--pathes-file', pathsFile.path, '--iphoto', '~/Pictures/Fotobibliothek'], 'w') { |io| io.write("") }

allIDs   = loadOutputFile(idsFile).map { |id| id.to_f.to_i.to_s }
allPaths = loadOutputFile(pathsFile)
[idsFile, pathsFile].each { |f| f.unlink }

allPhotoData = allIDs.zip(allPaths)
newPhotoData = allPhotoData.reject { |photoData| uploadedPhotos.get photoData.first }

puts "\n#{allPhotoData.length} photos in iPhoto library"
puts "#{newPhotoData.length} photos not yet uploaded to Flickr\n"

rawAlbumData = loadOutputFile(albumsFile)
albumsFile.unlink

albumEnum = rawAlbumData.each
albumData = {}
loop do
  albumEnum.next while albumEnum.peek.empty?
  albumId = albumEnum.next.to_f.to_i.to_s
  albumName = albumEnum.next
  albumData[albumId] = {name: albumName, photoIDs: []}
  albumPhotoIds = albumData[albumId][:photoIDs]
  while not (nextId = albumEnum.next).empty?
    albumPhotoIds << nextId.to_f.to_i.to_s
  end
end


# upload new files

MAX_SIZE = 1024 ** 3
class ErrTooBig < RuntimeError; def to_s; 'File is too big'; end; end

newPhotoData.each_with_index do |photoData, i|
  iPhotoID, photoPath = photoData
  unsupported = %w(.bmp .AVI .MOV)
  if !photoPath.end_with? *unsupported 
  tries = 0
  begin
    tries += 1
    print "#{i + 1}. Uploading '#{photoPath}' ... "
    raise ErrTooBig if File.size(photoPath) > MAX_SIZE
    flickrID = rateLimit { flickr.upload_photo photoPath }
    raise 'Invalid Flickr ID returned' unless flickrID.is_a? String  # this can happen, but I'm not yet sure what it means
    puts uploadedPhotos.add iPhotoID, flickrID
  
  rescue ErrTooBig, Errno::ENOENT, Errno::EINVAL => e  # in the face of missing/large/weird files, don't retry
    puts e
    puts

  # keep trying in face of network errors: Timeout::Error, Errno::BROKEN_PIPE, SocketError, ...
  rescue => err
    
    if (tries <= 3)
      if ((err.is_a? FlickRaw::FailedResponse) && 
        !(err.code == 3 || err.code == 6 || err.code == 105 || err.code == 106))
        
        # These error codes will possibly be recoverable, do not retry for others
        # 3: General upload failure
        # 6: User exceeded upload limit
        # 105: Service currently unavailable
        # 106: Write operation failed
        if 
          #non recoverable error
          puts "#{err.message} (#{err.code}) - Not recoverable, skipping image."
        end
      else
        #Possibly recoverable error code
        print "#{err.message}: retrying in 10s "; 10.times { sleep 1; print '.' }; puts
        retry
      end
    else
      # Too many failures
      puts "Too many failures, skipping"
    end
  end

end


# update albums/photosets

SET_NOT_FOUND   = 1
PHOTO_NOT_FOUND = 2

puts "\n#{albumData.length} standard albums in iPhoto\n"

albumData.each do |albumID, album|
  photosetID = createdAlbums.get albumID

  if photosetID.nil?
    print "Creating new photoset: '#{album[:name]}' ... "
    somePhotoID = album[:photoIDs].first
    someFlickrPhotoID = uploadedPhotos.get somePhotoID

    begin
      photosetID = rateLimit { flickr.photosets.create(title: album[:name], primary_photo_id: someFlickrPhotoID).id }

    rescue FlickRaw::FailedResponse => e
      if e.code == PHOTO_NOT_FOUND  # photoset cannot be created if primary photo has been deleted from Flickr
        print e.msg, ' ... '
        photosetID = 'X'
      else raise e
      end
    end

    puts createdAlbums.add albumID, photosetID
    photosInAlbums.add somePhotoID, albumID
  end

  # add any new photos
  album[:photoIDs].each do |iPhotoID|

    unless photosInAlbums.associated? iPhotoID, albumID
      flickrPhotoID = uploadedPhotos.get iPhotoID
      print "Adding photo #{iPhotoID} -> #{flickrPhotoID} to photoset #{albumID} -> #{photosetID} ... "
      errorHappened = false

      begin
        rateLimit { flickr.photosets.addPhoto(photoset_id: photosetID, photo_id: flickrPhotoID) }
      rescue FlickRaw::FailedResponse => e
        if [SET_NOT_FOUND, PHOTO_NOT_FOUND].include? e.code  
          puts e.msg
          errorHappened = true
        else raise e
        end
      end

      puts "done" unless errorHappened
      photosInAlbums.add iPhotoID, albumID
    end
  end

end

end; end; end  # own records blocks
puts  # I prefer some whitespace before the prompt
