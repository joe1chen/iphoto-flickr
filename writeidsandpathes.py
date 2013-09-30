import sys,os.path, codecs


sys.path.append(os.path.join(os.path.dirname(__file__), 'phoshare'))

import appledata.iphotodata as iphotodata
import tilutil.systemutils as su
from optparse import OptionParser

USAGE = """usage: %prog [options]

"""

def get_option_parser():
    """Gets an OptionParser for the Phoshare command line tool options."""
    p = OptionParser(usage=USAGE)
    
    p.add_option("--iphoto",
                 help="""Path to iPhoto library, e.g.
                 "%s/Pictures/iPhoto Library".""",
                 default="~/Pictures/iPhoto Library")
    p.add_option("--ids-file",help="path to write ids to")
    p.add_option("--pathes-file", help="path to write pathes to")  
    p.add_option("--albums-file", help="path to write album info to")           
    return p


def main():
    parser = get_option_parser()
    (options, args) = parser.parse_args()
    if not options.iphoto:
        parser.error("Need to specify the iPhoto library with the --iphoto "
                     "option.")            
    
    album_xml_file = iphotodata.get_album_xmlfile(
        su.expand_home_folder(options.iphoto))
    data = iphotodata.get_iphoto_data(album_xml_file)
    
    
    if options.pathes_file and options.ids_file:
        f_pathes = codecs.open(options.pathes_file,'w',"utf-16be")
        f_ids = codecs.open(options.ids_file,'w',"utf-16be")
        for image in data.images_by_id.values():
            f_ids.write(image.key)
            f_ids.write("\0")
            f_pathes.write(image.getimagepath())
            f_pathes.write("\0")
    
        f_pathes.close
        f_ids.close     
    
    if options.albums_file:
        f_albums = codecs.open(options.albums_file,'w',"utf-16be")
        events = data._getrolls();
        for event in events:
            f_albums.write("")
            f_albums.write("\0")
            f_albums.write(event.albumid)
            f_albums.write("\0")
            f_albums.write(event.name)
            f_albums.write("\0")
            f_albums.write("")
           # f_albums.write("\0")
            
            for image in event.images:
                f_albums.write(image.key)
                f_albums.write("\0")
            
            f_albums.write("\0")
            f_albums.write("\0")
            
    
    
if __name__ == "__main__":
    main()