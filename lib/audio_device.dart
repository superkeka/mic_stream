enum AudioDirection{
  Input,
  Output
}

class AudioDevice
{
   String Uid;
   String Name;
   AudioDirection Direction;
   AudioDevice(this.Uid, this.Name, this.Direction);

   @override
   String toString() {
     return "$Uid $Name ${Direction.toString()}";
   }
}